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

  func testWindowFindCommandsStayInOpenFileFindBar() async {
    let store = WorkspaceStore()
    store.showingInspector = true
    store.pane = "files"
    store.workspace.root = URL(fileURLWithPath: "/fixture")
    store.workspace.selectedFile = "Find.txt"
    store.workspace.openFiles = ["Find.txt"]
    store.workspace.fileText = "one one"
    let finder = store.workspace.fileFind
    finder.query = "one"
    finder.open(editor: nil, source: store.workspace.fileText)
    for _ in 0..<30 {
      if finder.matches.count == 2 { break }
      try? await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertEqual(finder.matches.count, 2)
    XCTAssertTrue(store.commandEnabled("find-next"))
    store.executeCommand("find-next")
    XCTAssertEqual(finder.selectedIndex, 1)
    store.executeCommand("find-previous")
    XCTAssertEqual(finder.selectedIndex, 0)
    store.executeCommand("find")
    XCTAssertTrue(finder.isPresented)
    XCTAssertFalse(store.showingFind)
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
    workspace.editSelectedFile("already written\n")
    try "already written\n".write(to: file, atomically: true, encoding: .utf8)
    let alreadySaved = await workspace.saveSelectedFileEdits()
    XCTAssertTrue(alreadySaved)
    XCTAssertNil(workspace.selectedFileEditor?.changedOnDisk)
    XCTAssertFalse(workspace.selectedFileEditor?.hasUnsavedChanges ?? true)
  }

  func testLargeUTF8FileOpensReadOnlyInsteadOfFailingPreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let large = String(repeating: "a", count: LocalWorkspaceService.maximumEditableTextBytes + 1)
    try large.write(to: root.appendingPathComponent("Large.txt"), atomically: true, encoding: .utf8)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("Large.txt")
    XCTAssertNil(workspace.fileError)
    XCTAssertEqual(workspace.fileText.utf8.count, large.utf8.count)
    XCTAssertTrue(workspace.fileIsReadOnly)
    XCTAssertNil(workspace.selectedFileEditor)
    try "small".write(to: root.appendingPathComponent("Large.txt"), atomically: true, encoding: .utf8)
    for _ in 0..<50 {
      if workspace.fileText == "small" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(workspace.fileText, "small")
    XCTAssertFalse(workspace.fileIsReadOnly)
    XCTAssertNotNil(workspace.selectedFileEditor)
  }

  func testExternalFileChangeRefreshesCleanEditorAndStopsDirtyAutosave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Watched.swift")
    try "first".write(to: file, atomically: true, encoding: .utf8)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("Watched.swift")
    try "external-one".write(to: file, atomically: true, encoding: .utf8)
    for _ in 0..<50 {
      if workspace.fileText == "external-one" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(workspace.fileText, "external-one")
    workspace.editSelectedFile("local")
    try "external-two".write(to: file, atomically: true, encoding: .utf8)
    for _ in 0..<50 {
      if workspace.selectedFileEditor?.changedOnDisk == "external-two" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(workspace.fileText, "local")
    XCTAssertEqual(workspace.selectedFileEditor?.changedOnDisk, "external-two")
    XCTAssertEqual(try String(contentsOf: file), "external-two")
  }

  func testBackgroundFileMonitorUpdatesOpenTabsWithoutReplacingSelectedText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.txt")
    let second = root.appendingPathComponent("second.txt")
    try "first".write(to: first, atomically: true, encoding: .utf8)
    try "second".write(to: second, atomically: true, encoding: .utf8)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("first.txt")
    await workspace.openFile("second.txt")
    let key = workspace.editorKey(for: "first.txt")
    try "outside".write(to: first, atomically: true, encoding: .utf8)
    for _ in 0..<50 {
      if workspace.fileEditorSessions[key]?.text == "outside" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(workspace.fileEditorSessions[key]?.text, "outside")
    XCTAssertEqual(workspace.selectedFile, "second.txt")
    XCTAssertEqual(workspace.fileText, "second")
  }

  func testBackgroundDraftDetectsConflictAndMatchingExternalWriteResolvesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.txt")
    try "first".write(to: first, atomically: true, encoding: .utf8)
    try "second".write(to: root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("first.txt")
    workspace.editSelectedFile("local")
    await workspace.openFile("second.txt")
    let key = workspace.editorKey(for: "first.txt")
    try "outside".write(to: first, atomically: true, encoding: .utf8)
    for _ in 0..<50 {
      if workspace.fileEditorSessions[key]?.changedOnDisk == "outside" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(workspace.fileEditorSessions[key]?.changedOnDisk, "outside")
    XCTAssertEqual(workspace.fileText, "second")
    try "local".write(to: first, atomically: true, encoding: .utf8)
    for _ in 0..<50 {
      if workspace.fileEditorSessions[key]?.hasUnsavedChanges == false { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertFalse(workspace.fileEditorSessions[key]?.hasUnsavedChanges ?? true)
    XCTAssertNil(workspace.fileEditorSessions[key]?.changedOnDisk)
    XCTAssertNil(workspace.fileEditorSessions[key]?.error)
    XCTAssertEqual(workspace.fileText, "second")
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

  func testPendingFileClosePausesOnlyItsAutosaveAndDiscardKeepsDisk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
    try "first".write(to: first, atomically: true, encoding: .utf8)
    try "second".write(to: second, atomically: true, encoding: .utf8)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    defer { workspace.setProject(nil) }
    await workspace.openFile("first.txt")
    workspace.editSelectedFile("discard this draft")
    await workspace.openFile("second.txt")
    workspace.editSelectedFile("save other file")
    workspace.closeFile("first.txt")
    // A monitor/conflict refresh must not rearm the paused file while its dialog is open.
    workspace.scheduleFileAutosave(key: first.path)
    try await Task.sleep(for: .milliseconds(3400))
    XCTAssertEqual(workspace.fileCloseRequest, "first.txt")
    XCTAssertTrue(workspace.openFiles.contains("first.txt"))
    XCTAssertEqual(try String(contentsOf: first), "first")
    XCTAssertEqual(try String(contentsOf: second), "save other file")
    XCTAssertEqual(workspace.fileEditorSessions[first.path]?.text, "discard this draft")
    workspace.discardAndCloseFile("first.txt")
    XCTAssertFalse(workspace.openFiles.contains("first.txt"))
    XCTAssertEqual(try String(contentsOf: first), "first")
  }

  func testCancelFileCloseResumesAutosaveAndExplicitSaveStillWorks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file.txt")
    try "original".write(to: file, atomically: true, encoding: .utf8)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    defer { workspace.setProject(nil) }
    await workspace.openFile("file.txt")
    workspace.editSelectedFile("keep editing")
    workspace.closeFile("file.txt")
    XCTAssertNil(workspace.fileAutosaveTasks[file.path])
    workspace.cancelFileClose()
    XCTAssertNil(workspace.fileCloseRequest)
    XCTAssertTrue(workspace.openFiles.contains("file.txt"))
    XCTAssertEqual(workspace.fileText, "keep editing")
    for _ in 0..<90 {
      if try String(contentsOf: file) == "keep editing" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(try String(contentsOf: file), "keep editing")
    workspace.editSelectedFile("explicit save")
    workspace.closeFile("file.txt")
    let saved = await workspace.saveSelectedFileEdits()
    XCTAssertTrue(saved)
    XCTAssertEqual(try String(contentsOf: file), "explicit save")
    workspace.fileCloseRequest = nil
    workspace.closeFile("file.txt")
    XCTAssertFalse(workspace.openFiles.contains("file.txt"))
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
