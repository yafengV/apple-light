import XCTest
@testable import ShipiOS

@MainActor
final class FileWorkspaceTests: XCTestCase {
  @MainActor private final class Reads {
    var pending: [String: CheckedContinuation<String, Error>] = [:]
    func read(_ path: String) async throws -> String {
      try await withCheckedThrowingContinuation { pending[path] = $0 }
    }
    func wait(_ path: String) async {
      for _ in 0..<1000 {
        if pending[path] != nil { return }
        await Task.yield()
      }
      XCTFail("Read did not start: \(path)")
    }
    func finish(_ path: String, _ result: Result<String, Error>) { pending.removeValue(forKey: path)?.resume(with: result) }
  }

  func testClosingLoadingFileIgnoresLateResultAndError() async {
    for failure in [false, true] {
      let reads = Reads()
      let workspace = DeveloperWorkspace(fileReader: { path, _ in try await reads.read(path) })
      workspace.root = URL(fileURLWithPath: "/fixture")
      let load = workspace.selectFile("closed.swift")
      await reads.wait("closed.swift")
      workspace.closeFile("closed.swift")
      reads.finish("closed.swift", failure ? .failure(AgentFailure(message: "late error")) : .success("late text"))
      await load?.value
      XCTAssertNil(workspace.selectedFile)
      XCTAssertTrue(workspace.openFiles.isEmpty)
      XCTAssertEqual(workspace.fileText, "")
      XCTAssertNil(workspace.fileError)
      XCTAssertFalse(workspace.fileLoading)
    }
  }

  func testOutOfOrderReadsCannotReplaceSelectedTab() async {
    let reads = Reads()
    let workspace = DeveloperWorkspace(fileReader: { path, _ in try await reads.read(path) })
    workspace.root = URL(fileURLWithPath: "/fixture")
    let first = workspace.selectFile("first")
    await reads.wait("first")
    let second = workspace.selectFile("second")
    await reads.wait("second")
    reads.finish("second", .success("second text")); await second?.value
    reads.finish("first", .success("first text")); await first?.value
    XCTAssertEqual(workspace.selectedFile, "second")
    XCTAssertEqual(workspace.fileText, "second text")
    XCTAssertFalse(workspace.fileLoading)
    workspace.closeFile("first")
    XCTAssertEqual(workspace.fileText, "second text")
  }

  func testCloseFallbackCannotReopenTabOrOverrideProjectChange() async {
    let reads = Reads()
    let workspace = DeveloperWorkspace(fileReader: { path, _ in try await reads.read(path) })
    workspace.root = URL(fileURLWithPath: "/fixture")
    workspace.openFiles = ["first", "second", "third"]
    workspace.selectedFile = "second"
    workspace.closeFile("second")
    XCTAssertEqual(workspace.selectedFile, "third")
    await reads.wait("third")
    workspace.closeFile("third")
    XCTAssertEqual(workspace.selectedFile, "first")
    await reads.wait("first")
    workspace.setProject(nil)
    reads.finish("third", .success("closed"))
    reads.finish("first", .success("old project"))
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNil(workspace.selectedFile)
    XCTAssertTrue(workspace.openFiles.isEmpty)
    XCTAssertEqual(workspace.fileText, "")
    XCTAssertFalse(workspace.fileLoading)
  }

  func testFailedFileCanRetryAndDoesNotOverwriteReviewError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.error = "review error"
    await workspace.openFile("new.swift")
    XCTAssertNotNil(workspace.fileError)
    XCTAssertEqual(workspace.error, "review error")
    try "恢复内容 👩🏽‍💻\n".write(to: root.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
    await workspace.openFile("new.swift")
    XCTAssertNil(workspace.fileError)
    XCTAssertEqual(workspace.fileText, "恢复内容 👩🏽‍💻\n")
    XCTAssertEqual(workspace.openFiles, ["new.swift"])
  }

  func testFileCommandsRespectSettingsOverlayAndLastTabFocus() async {
    let store = WorkspaceStore()
    store.workspace = DeveloperWorkspace(fileReader: { path, _ in path })
    store.workspace.root = URL(fileURLWithPath: "/fixture")
    store.showingInspector = true
    store.pane = "files"
    await store.workspace.openFile("first")
    await store.workspace.openFile("second")
    let originalFocus = store.focusComposer
    XCTAssertTrue(store.handleFileShortcut(ShortcutBinding("⌃⇧⇥")))
    XCTAssertEqual(store.workspace.selectedFile, "first")
    XCTAssertTrue(store.handleFileShortcut(ShortcutBinding("⌃⇧⇥")))
    XCTAssertEqual(store.workspace.selectedFile, "second")
    store.openSettings(.general)
    XCTAssertFalse(store.handleFileShortcut(ShortcutBinding("⌘W")))
    XCTAssertEqual(store.workspace.openFiles.count, 2)
    store.closeSettings()
    store.showingFileSearch = true
    XCTAssertFalse(store.handleFileShortcut(ShortcutBinding("⌃⇥")))
    store.showingFileSearch = false
    XCTAssertTrue(store.handleFileShortcut(ShortcutBinding("⌘W")))
    XCTAssertEqual(store.workspace.selectedFile, "first")
    XCTAssertTrue(store.handleFileShortcut(ShortcutBinding("⌘W")))
    XCTAssertTrue(store.workspace.openFiles.isEmpty)
    XCTAssertNotEqual(store.focusComposer, originalFocus)
    XCTAssertTrue(store.showingInspector)
    XCTAssertFalse(store.handleFileShortcut(ShortcutBinding("⌘W")))
  }

  func testSearchDismissalFocusOnlyReturnsToMatchingFileScope() async {
    let store = WorkspaceStore()
    store.workspace = DeveloperWorkspace(fileReader: { path, _ in path })
    let root = URL(fileURLWithPath: "/fixture")
    store.workspace.root = root
    store.pane = "files"; store.showingInspector = true
    await store.workspace.openFile("first")
    let composerFocus = store.focusComposer
    let fileFocus = store.workspace.fileFocusRequest
    store.fileFocusAfterOverlay = (root, "first")
    store.restoreOverlayFocus()
    XCTAssertNotEqual(store.workspace.fileFocusRequest, fileFocus)
    XCTAssertEqual(store.focusComposer, composerFocus)
    store.fileFocusAfterOverlay = (root, "other")
    store.restoreOverlayFocus()
    XCTAssertNotEqual(store.focusComposer, composerFocus)
    store.fileFocusAfterOverlay = (root, "first")
    store.openSettings()
    let focusInSettings = store.focusComposer
    store.restoreOverlayFocus()
    XCTAssertEqual(store.focusComposer, focusInSettings)
    XCTAssertNil(store.fileFocusAfterOverlay)
  }

  func testLineSelectionUsesNativeUnicodeOffsetsAndRejectsInvalidLines() {
    let text = "👩🏽‍💻 Café\r\n中文\nlast"
    let range = FileLineLocation.range("2", in: text)!
    XCTAssertEqual((text as NSString).substring(with: range), "中文")
    XCTAssertEqual((text as NSString).substring(with: FileLineLocation.range("3", in: text)!), "last")
    for value in ["0", "-1", "4", "abc", "1:2", "999999999999999999999999999"] {
      XCTAssertNil(FileLineLocation.range(value, in: text), value)
    }
    XCTAssertEqual(FileLineLocation.range("2", in: "first\n"), NSRange(location: 6, length: 0))
    XCTAssertEqual(FileLineLocation.range("1", in: ""), NSRange(location: 0, length: 0))
    XCTAssertNil(FileLineLocation.range("2", in: ""))
  }

  func testEditorSavesTextPreservesPermissionsAndRequiresConflictResolution() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("script.sh")
    try "original\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("script.sh")
    XCTAssertNotNil(workspace.selectedFileEditor)
    workspace.editSelectedFile("edited\n")
    let saved = await workspace.saveSelectedFileEdits()
    XCTAssertTrue(saved)
    XCTAssertEqual(try String(contentsOf: file), "edited\n")
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o755)
    try "external\n".write(to: file, atomically: true, encoding: .utf8)
    workspace.editSelectedFile("local\n")
    let conflicted = await workspace.saveSelectedFileEdits()
    XCTAssertFalse(conflicted)
    XCTAssertEqual(try String(contentsOf: file), "external\n")
    XCTAssertEqual(workspace.selectedFileEditor?.changedOnDisk, "external\n")
    let resolved = await workspace.useLocalFileEditsAfterConflict()
    XCTAssertTrue(resolved)
    XCTAssertEqual(try String(contentsOf: file), "local\n")
    XCTAssertFalse(workspace.selectedFileEditor?.hasUnsavedChanges ?? true)
  }

  func testEditorKeepsDraftAcrossTabsAndPromptsBeforeClosingDirtyFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "first".write(to: root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    try "second".write(to: root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("first.txt")
    workspace.editSelectedFile("local draft")
    await workspace.openFile("second.txt")
    await workspace.openFile("first.txt")
    XCTAssertEqual(workspace.fileText, "local draft")
    workspace.closeFile("first.txt")
    XCTAssertEqual(workspace.fileCloseRequest, "first.txt")
    XCTAssertTrue(workspace.openFiles.contains("first.txt"))
    workspace.discardAndCloseFile("first.txt")
    XCTAssertFalse(workspace.openFiles.contains("first.txt"))
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("first.txt")), "first")
  }

  func testEditorAutosavesAndCannotSaveAfterAttachedFolderRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let primary = root.appendingPathComponent("Primary")
    let attached = root.appendingPathComponent("Attached")
    try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: attached, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let primaryFile = primary.appendingPathComponent("auto.txt")
    let attachedFile = attached.appendingPathComponent("attached.txt")
    try "before".write(to: primaryFile, atomically: true, encoding: .utf8)
    try "attached".write(to: attachedFile, atomically: true, encoding: .utf8)
    let workspace = DeveloperWorkspace()
    workspace.root = primary
    workspace.setAdditionalFileRoots([attached])
    await workspace.openFile("auto.txt")
    workspace.editSelectedFile("autosaved")
    for _ in 0..<80 {
      if try String(contentsOf: primaryFile) == "autosaved" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(try String(contentsOf: primaryFile), "autosaved")
    await workspace.openFile(attachedFile.path)
    workspace.editSelectedFile("should not save")
    workspace.setAdditionalFileRoots([])
    let outOfScope = await workspace.saveFileEdits(key: attachedFile.path)
    XCTAssertFalse(outOfScope)
    XCTAssertEqual(try String(contentsOf: attachedFile), "attached")
  }

  func testUnsavedEditorDraftSurvivesWorkspaceReloadAndStillChecksDiskConflict() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project")
    let dataRoot = root.appendingPathComponent("Data")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = project.appendingPathComponent("Recovery.swift")
    try "original".write(to: file, atomically: true, encoding: .utf8)
    let first = WorkspaceStore(dataRoot: dataRoot)
    await first.restore()
    first.workspace.root = project
    await first.workspace.openFile("Recovery.swift")
    first.workspace.editSelectedFile("unsaved draft")
    first.captureFileEditorRecovery(from: first.workspace)
    let savedLibrary = try WorkspaceLibrary.load(from: dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(savedLibrary.fileEditorRecovery[file.path]?.text, "unsaved draft")
    await first.shutdown()

    try "external".write(to: file, atomically: true, encoding: .utf8)
    let restored = WorkspaceStore(dataRoot: dataRoot)
    await restored.restore()
    restored.workspace.root = project
    await restored.workspace.openFile("Recovery.swift")
    XCTAssertEqual(restored.workspace.fileText, "unsaved draft")
    let save = await restored.workspace.saveSelectedFileEdits()
    XCTAssertFalse(save)
    XCTAssertEqual(try String(contentsOf: file), "external")
    XCTAssertEqual(restored.workspace.selectedFileEditor?.changedOnDisk, "external")
    restored.workspace.discardSelectedFileEdits()
    XCTAssertNil(restored.library.fileEditorRecovery[file.path])
    await restored.shutdown()
  }

  func testTaskWindowClosePreservesItsFileDraftForReopening() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = project.appendingPathComponent("Task.swift")
    try "before".write(to: file, atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    store.library.tasks = [WorkspaceTask(id: "task", project: project.path, title: "Task",
      runIDs: [], createdAt: Date(), updatedAt: Date())]
    let first = TaskWindowResources()
    first.prepare("task", store: store)
    let workspace = try XCTUnwrap(first.panels.tasks["task"]?.workspace)
    await workspace.openFile("Task.swift")
    workspace.editSelectedFile("task draft")
    first.shutdown()
    XCTAssertEqual(store.library.fileEditorRecovery[file.path]?.text, "task draft")
    let second = TaskWindowResources()
    second.prepare("task", store: store)
    let reopened = try XCTUnwrap(second.panels.tasks["task"]?.workspace)
    await reopened.openFile("Task.swift")
    XCTAssertEqual(reopened.fileText, "task draft")
    second.shutdown()
    await store.shutdown()
  }
}
