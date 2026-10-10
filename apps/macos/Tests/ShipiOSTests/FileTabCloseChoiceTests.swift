import XCTest
@testable import ShipiOS

@MainActor final class FileTabCloseChoiceTests: XCTestCase {
  @MainActor private struct Fixture {
    let store: WorkspaceStore
    let resources: TaskWindowResources?
    let tabs: TaskWindowTabs?
    let editor: DeveloperWorkspace
    let tab: WorkspaceContentTab
    let root: URL
    var file: URL { root.appendingPathComponent("one.txt") }
    var containsTab: Bool { tabs?.tabs.contains(tab) ?? store.workspaceTabs.contains(tab) }
    func close() { if let tabs { tabs.close(tab.id) } else { store.closeWorkspaceTab(tab.id) } }
    func completeClose() {
      if let resources { resources.closeFileContentTab(tab, taskID: "task", editor: editor) }
      else { store.closeFileContentTab(tab, editor: editor) }
    }
    func saveChoice() async -> Bool {
      let saved = await editor.saveAndCloseRequestedFile()
      if saved { completeClose() }
      return saved
    }
    func discardChoice() -> Bool {
      let discarded = editor.discardRequestedFileClose()
      if discarded { completeClose() }
      return discarded
    }
  }

  private func fixture(taskWindow: Bool) async throws -> Fixture {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let base = temporary.resolvingSymlinksInPath(), root = base.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "原文件\n".write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    try "unrelated".write(to: root.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.project = root; store.workspace.setProject(root)
    store.library.tasks = [.init(id: "task", project: root.path, title: "Task", runIDs: [])]
    store.selection = "task"; store.restoreWorkspaceTabLayout(); store.draft = "conversation draft"
    let resources: TaskWindowResources?, tabs: TaskWindowTabs?, tab: WorkspaceContentTab, editor: DeveloperWorkspace
    if taskWindow {
      let result = TaskWindowResources(); result.prepare("task", store: store, windowID: "child")
      let target = try XCTUnwrap(result.tasks["task"])
      XCTAssertTrue(target.openFile("one.txt")); tab = try XCTUnwrap(target.focused)
      resources = result; tabs = target; editor = result.fileWorkspace(tab)
    } else {
      XCTAssertTrue(store.openFileTab("one.txt")); tab = try XCTUnwrap(store.focusedWorkspaceContentTab)
      resources = nil; tabs = nil; editor = store.fileTabWorkspace(tab)
    }
    editor.setProject(root); await editor.openFile("one.txt")
    XCTAssertEqual(editor.fileText, "原文件\n")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("未保存 👩🏽‍💻\n")
    addTeardownBlock { @MainActor in
      resources?.shutdown(); editor.setProject(nil); store.workspace.setProject(nil)
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: base)
    }
    return .init(store: store, resources: resources, tabs: tabs, editor: editor, tab: tab, root: root)
  }

  private func checkSave(_ child: Bool) async throws {
    let f = try await fixture(taskWindow: child)
    f.close(); let request = f.editor.fileCloseRequestID; f.close()
    XCTAssertEqual(f.editor.fileCloseRequestID, request)
    XCTAssertTrue(f.containsTab)
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "原文件\n")
    let saved = await f.saveChoice(); XCTAssertTrue(saved)
    XCTAssertFalse(f.containsTab); XCTAssertNil(f.editor.fileCloseRequest)
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "未保存 👩🏽‍💻\n")
    XCTAssertEqual(f.store.draft, "conversation draft")
    XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("two.txt"), encoding: .utf8), "unrelated")
  }
  private func checkDiscard(_ child: Bool) async throws {
    let f = try await fixture(taskWindow: child); f.close()
    XCTAssertTrue(f.store.captureFileEditorRecovery(from: f.editor))
    let key = f.editor.editorKey(for: "one.txt")
    XCTAssertNotNil(f.store.library.fileEditorRecovery[key])
    XCTAssertTrue(f.discardChoice()); XCTAssertFalse(f.containsTab)
    XCTAssertNil(f.editor.fileCloseRequest)
    XCTAssertNil(f.store.library.fileEditorRecovery[key])
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "原文件\n")
    XCTAssertEqual(f.store.draft, "conversation draft")
  }
  private func checkCancel(_ child: Bool) async throws {
    let f = try await fixture(taskWindow: child); f.close()
    let request = f.editor.fileCloseRequestID, focus = f.editor.fileFocusRequest
    f.editor.cancelFileClose()
    XCTAssertTrue(f.containsTab); XCTAssertNil(f.editor.fileCloseRequest)
    XCTAssertNotEqual(f.editor.fileFocusRequest, focus)
    XCTAssertEqual(f.editor.fileText, "未保存 👩🏽‍💻\n")
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "原文件\n")
    f.close(); XCTAssertNotEqual(f.editor.fileCloseRequestID, request)
    XCTAssertTrue(f.discardChoice())
  }
  private func checkFailure(_ child: Bool) async throws {
    let f = try await fixture(taskWindow: child); f.close()
    let backup = f.root.appendingPathComponent("original-backup")
    try FileManager.default.moveItem(at: f.file, to: backup)
    try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
    let saved = await f.saveChoice(); XCTAssertFalse(saved)
    XCTAssertTrue(f.containsTab); XCTAssertEqual(f.editor.fileCloseRequest, "one.txt")
    XCTAssertEqual(f.editor.fileText, "未保存 👩🏽‍💻\n")
    XCTAssertTrue(f.editor.selectedFileEditor?.hasUnsavedChanges == true)
    XCTAssertNotNil(f.editor.selectedFileEditor?.error)
    XCTAssertFalse(f.editor.selectedFileEditor?.saving == true)
    try FileManager.default.removeItem(at: f.file)
    try FileManager.default.moveItem(at: backup, to: f.file)
    let retried = await f.saveChoice(); XCTAssertTrue(retried)
    XCTAssertFalse(f.containsTab)
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "未保存 👩🏽‍💻\n")
  }
  private func checkConflict(_ child: Bool) async throws {
    let f = try await fixture(taskWindow: child); f.close()
    try "external".write(to: f.file, atomically: true, encoding: .utf8)
    let saved = await f.saveChoice(); XCTAssertFalse(saved)
    XCTAssertTrue(f.containsTab); XCTAssertEqual(f.editor.fileCloseRequest, "one.txt")
    XCTAssertEqual(f.editor.selectedFileEditor?.changedOnDisk, "external")
    XCTAssertEqual(f.editor.fileText, "未保存 👩🏽‍💻\n")
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "external")
    XCTAssertTrue(f.discardChoice()); XCTAssertFalse(f.containsTab)
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "external")
  }
  private func checkBackground(_ child: Bool) async throws {
    let f = try await fixture(taskWindow: child)
    if let tabs = f.tabs { XCTAssertTrue(tabs.openFile("two.txt")) }
    else { XCTAssertTrue(f.store.openFileTab("two.txt")) }
    f.close()
    XCTAssertEqual(f.tabs?.focused?.id ?? f.store.focusedWorkspaceContentTab?.id, f.tab.id)
    XCTAssertEqual(f.editor.fileCloseRequest, "one.txt")
    XCTAssertTrue(f.containsTab)
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "原文件\n")
    XCTAssertTrue(f.discardChoice())
  }

  private func checkReplacedSave(_ child: Bool) async throws {
    let f = try await fixture(taskWindow: child); f.close()
    let oldRequest = f.editor.fileCloseRequestID
    let save = Task { await f.saveChoice() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while f.editor.selectedFileEditor?.saving != true && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(f.editor.selectedFileEditor?.saving == true)
    f.editor.cancelFileClose(); f.editor.closeFile("one.txt")
    XCTAssertNotEqual(f.editor.fileCloseRequestID, oldRequest)
    let completed = await save.value
    XCTAssertFalse(completed, "The old save cannot close the replacement request or its tab")
    XCTAssertTrue(f.containsTab)
    XCTAssertEqual(f.editor.fileCloseRequest, "one.txt")
    // The first explicit save was authorized; replacing its close request must
    // retain the tab even if that write has already completed.
    XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "未保存 👩🏽‍💻\n")
    XCTAssertTrue(f.discardChoice())
  }

  func testMainSaveChoiceWritesOnlyConfirmedFile() async throws { try await checkSave(false) }
  func testTaskSaveChoiceWritesOnlyConfirmedFile() async throws { try await checkSave(true) }
  func testMainDiscardClosesWithoutWritingAndClearsRecovery() async throws { try await checkDiscard(false) }
  func testTaskDiscardClosesWithoutWritingAndClearsRecovery() async throws { try await checkDiscard(true) }
  func testMainContinueEditingKeepsDraftAndRestoresFocus() async throws { try await checkCancel(false) }
  func testTaskContinueEditingKeepsDraftAndRestoresFocus() async throws { try await checkCancel(true) }
  func testMainSaveFailurePreservesRequestAndRetries() async throws { try await checkFailure(false) }
  func testTaskSaveFailurePreservesRequestAndRetries() async throws { try await checkFailure(true) }
  func testMainConflictCannotOverwriteExternalChange() async throws { try await checkConflict(false) }
  func testTaskConflictCannotOverwriteExternalChange() async throws { try await checkConflict(true) }
  func testMainBackgroundCloseRevealsConfirmationOwner() async throws { try await checkBackground(false) }
  func testTaskBackgroundCloseRevealsConfirmationOwner() async throws { try await checkBackground(true) }
  func testMainOldSaveCannotCompleteNewCloseRequest() async throws { try await checkReplacedSave(false) }
  func testTaskOldSaveCannotCompleteNewCloseRequest() async throws { try await checkReplacedSave(true) }
}
