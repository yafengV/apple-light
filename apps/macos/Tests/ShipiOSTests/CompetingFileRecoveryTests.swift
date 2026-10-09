import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class CompetingFileRecoveryTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, URL) {
    _ = NSApplication.shared
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "original".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.project = root; store.workspace.setProject(root)
    store.library.tasks = [.init(id: "task", project: root.path, title: "Task", runIDs: [])]
    store.selection = "task"; store.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      for resources in store.taskWindowResources.allObjects { resources.shutdown() }
      store.workspace.setProject(nil); store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      for editor in store.fileTabWorkspaces.values { editor.setProject(nil) }
      try? FileManager.default.removeItem(at: base)
    }
    return (store, root)
  }

  private func editor(_ store: WorkspaceStore, windowID: String) async throws -> (TaskWindowResources, DeveloperWorkspace) {
    let resources = TaskWindowResources(); resources.prepare("task", store: store, windowID: windowID)
    let tabs = try XCTUnwrap(resources.tasks["task"])
    if tabs.focused == nil { XCTAssertTrue(tabs.openFile("same.txt")) }
    let editor = resources.fileWorkspace(try XCTUnwrap(tabs.focused))
    editor.setProject(tabs.panels.workspace.root); await editor.openFile("same.txt")
    addTeardownBlock { @MainActor in resources.shutdown() }
    return (resources, editor)
  }

  private func cold(_ store: WorkspaceStore) throws -> WorkspaceStore {
    let result = WorkspaceStore(dataRoot: store.dataRoot)
    result.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    result.libraryLoaded = true; result.scopeLoaded = true; result.connected = true
    result.project = store.project; result.workspace.setProject(store.project)
    result.selection = store.selection; result.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      for resources in result.taskWindowResources.allObjects { resources.shutdown() }
      result.workspace.setProject(nil); result.workspace.browser.shutdown(); result.workspace.terminals.shutdown()
    }
    return result
  }

  private func competing(_ store: WorkspaceStore) async throws {
    let (first, a) = try await editor(store, windowID: "first")
    let (second, b) = try await editor(store, windowID: "second")
    a.beginEditingSelectedFile(); a.editSelectedFile("first draft")
    b.beginEditingSelectedFile(); b.editSelectedFile("second draft")
    first.shutdown(); second.shutdown()
  }

  func testColdTaskWindowsRestoreTheirOwnCompetingDrafts() async throws {
    let (store, root) = try fixture(); try await competing(store)
    let restored = try cold(store)
    let (first, a) = try await editor(restored, windowID: "first")
    let (second, b) = try await editor(restored, windowID: "second")
    XCTAssertEqual(a.fileText, "first draft"); XCTAssertEqual(b.fileText, "second draft")
    XCTAssertEqual(a.selectedFileEditor?.baseText, "original")
    XCTAssertEqual(b.selectedFileEditor?.baseText, "original")
    XCTAssertFalse(a === b)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("same.txt"), encoding: .utf8), "original")
    for (resources, expected) in [(first, "first draft"), (second, "second draft")] {
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let tabs = try XCTUnwrap(resources.tasks["task"])
      window.contentView = NSHostingView(rootView: TaskWindowView(store: restored, taskID: "task", tabs: tabs,
        resources: resources, renameHistory: TaskRenameHistory(), onNavigate: { _ in },
        canGoBack: false, canGoForward: false, onMove: { _ in }))
      defer { window.contentView = nil; window.close() }
      func preview(_ view: NSView?) -> FilePreviewTextView? {
        guard let view else { return nil }
        if let result = view as? FilePreviewTextView { return result }
        return view.subviews.lazy.compactMap { preview($0) }.first
      }
      for _ in 0..<40 where preview(window.contentView) == nil {
        try await Task.sleep(for: .milliseconds(25)); window.contentView?.layoutSubtreeIfNeeded()
      }
      XCTAssertEqual(try XCTUnwrap(preview(window.contentView)).string, expected)
      XCTAssertFalse(window.isVisible)
    }
  }

  func testDiscardingOneRecoveredVersionKeepsOtherWindowDraft() async throws {
    let (store, root) = try fixture(); try await competing(store)
    let restored = try cold(store)
    let (_, a) = try await editor(restored, windowID: "first")
    XCTAssertEqual(a.fileText, "first draft")
    a.discardSelectedFileEdits()
    await a.openFile("same.txt")
    XCTAssertEqual(a.fileText, "original")
    let afterDiscard = try cold(restored)
    let (_, b) = try await editor(afterDiscard, windowID: "second")
    XCTAssertEqual(b.fileText, "second draft")
    XCTAssertEqual(b.selectedFileEditor?.baseText, "original")
    let saved = await b.saveSelectedFileEdits(); XCTAssertTrue(saved)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("same.txt"), encoding: .utf8), "second draft")
    XCTAssertNil(afterDiscard.library.fileEditorRecovery[b.editorKey(for: "same.txt")])
  }

  func testUnrecoveredEditorSaveCannotClearAnotherWindowsPersistedDraft() async throws {
    let (store, root) = try fixture()
    let (first, a) = try await editor(store, windowID: "first")
    let (_, b) = try await editor(store, windowID: "second")
    a.beginEditingSelectedFile(); a.editSelectedFile("first draft"); first.shutdown()
    b.beginEditingSelectedFile(); b.editSelectedFile("saved second")
    let saved = await b.saveSelectedFileEdits(); XCTAssertTrue(saved)
    let restored = try cold(store)
    let (_, recovered) = try await editor(restored, windowID: "first")
    XCTAssertEqual(recovered.fileText, "first draft")
    let conflicted = await recovered.saveSelectedFileEdits(); XCTAssertFalse(conflicted)
    XCTAssertEqual(recovered.selectedFileEditor?.changedOnDisk, "saved second")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("same.txt"), encoding: .utf8), "saved second")
  }

  func testTaskFilePanelRootChangeCapturesDraftBeforeReset() async throws {
    let (store, root) = try fixture()
    let next = root.deletingLastPathComponent().appendingPathComponent("Next")
    try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
    try "next disk".write(to: next.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
    let resources = TaskWindowResources(); resources.prepare("task", store: store, windowID: "tree")
    defer { resources.shutdown() }
    let panel = try XCTUnwrap(resources.panels.tasks["task"]?.workspace)
    await panel.openFile("same.txt"); panel.beginEditingSelectedFile(); panel.editSelectedFile("old tree draft")
    store.library.tasks[0].project = next.path
    resources.prepare("task", store: store)
    XCTAssertEqual(panel.root?.path, GitBranchService.canonicalRoot(next).path)
    let key = GitBranchService.canonicalRoot(root).appendingPathComponent("same.txt").path
    XCTAssertEqual(store.library.fileEditorRecovery[key]?.text, "old tree draft")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("same.txt"), encoding: .utf8), "original")
    XCTAssertEqual(try String(contentsOf: next.appendingPathComponent("same.txt"), encoding: .utf8), "next disk")
  }

  func testSavingOneRecoveredVersionKeepsOtherAndStillRequiresConflictResolution() async throws {
    let (store, root) = try fixture(); try await competing(store)
    let restored = try cold(store)
    let (_, a) = try await editor(restored, windowID: "first")
    let firstSaved = await a.saveSelectedFileEdits(); XCTAssertTrue(firstSaved)
    let afterSave = try cold(restored)
    let (_, b) = try await editor(afterSave, windowID: "second")
    XCTAssertEqual(b.fileText, "second draft")
    let secondSaved = await b.saveSelectedFileEdits(); XCTAssertFalse(secondSaved)
    XCTAssertEqual(b.selectedFileEditor?.changedOnDisk, "first draft")
    let confirmed = await b.useLocalFileEditsAfterConflict(); XCTAssertTrue(confirmed)
    XCTAssertNil(afterSave.library.fileEditorRecovery[b.editorKey(for: "same.txt")])
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("same.txt"), encoding: .utf8), "second draft")
  }

  func testNewWindowFallbackCanResolveRemainingVersionsWithoutOriginalWindow() async throws {
    let (store, _) = try fixture(); try await competing(store)
    let restored = try cold(store)
    let (newWindow, latest) = try await editor(restored, windowID: "new-window")
    XCTAssertEqual(latest.fileText, "second draft")
    latest.discardSelectedFileEdits(); newWindow.shutdown()
    let (_, remaining) = try await editor(restored, windowID: "another-new-window")
    XCTAssertEqual(remaining.fileText, "first draft")
    remaining.discardSelectedFileEdits()
    XCTAssertNil(restored.library.fileEditorRecovery[remaining.editorKey(for: "same.txt")])
  }

  func testMainAndTaskFileRecoveryKeepSeparateVersions() async throws {
    let (store, root) = try fixture()
    XCTAssertTrue(store.openFileTab("same.txt"))
    let tab = try XCTUnwrap(store.focusedWorkspaceContentTab), main = store.fileTabWorkspace(tab)
    main.setProject(root); await main.openFile("same.txt")
    let (childWindow, child) = try await editor(store, windowID: "child")
    main.beginEditingSelectedFile(); main.editSelectedFile("main draft")
    child.beginEditingSelectedFile(); child.editSelectedFile("child draft")
    store.captureFileEditorRecovery(from: main); childWindow.shutdown()
    let restored = try cold(store)
    let mainTab = try XCTUnwrap(restored.workspaceTabs.first { $0.kind == .file })
    let mainEditor = restored.fileTabWorkspace(mainTab)
    defer { mainEditor.setProject(nil) }
    mainEditor.setProject(root); await mainEditor.openFile("same.txt")
    let (_, childEditor) = try await editor(restored, windowID: "child")
    XCTAssertEqual(mainEditor.fileText, "main draft"); XCTAssertEqual(childEditor.fileText, "child draft")
  }

  func testLegacyRecordMigratesWithoutKeepingAnObsoleteVersion() async throws {
    let (store, root) = try fixture()
    let key = GitBranchService.canonicalRoot(root).appendingPathComponent("same.txt").path
    let old = try JSONDecoder().decode(FileEditorRecoveryDraft.self,
      from: Data(#"{"baseText":"original","text":"legacy draft"}"#.utf8))
    store.library.fileEditorRecovery[key] = old; store.saveLibrary()
    let (source, draft) = try await editor(store, windowID: "first")
    XCTAssertEqual(draft.fileText, "legacy draft")
    draft.editSelectedFile("continued legacy draft"); source.shutdown()
    let record = try XCTUnwrap(store.library.fileEditorRecovery[key])
    XCTAssertEqual(record.versions.count, 1); XCTAssertEqual(record.text, "continued legacy draft")
    let restored = try cold(store), (_, reopened) = try await editor(restored, windowID: "first")
    XCTAssertEqual(reopened.fileText, "continued legacy draft")
  }

  func testBulkPromotionMovesRecoveryContextWithExistingEditor() async throws {
    let (store, root) = try fixture()
    let target = WorkspaceTask(id: "target", project: root.path, title: "Target", runIDs: [])
    store.library.tasks.append(target)
    XCTAssertTrue(store.openFileTab("same.txt"))
    let tab = try XCTUnwrap(store.focusedWorkspaceContentTab), main = store.fileTabWorkspace(tab)
    main.setProject(root); await main.openFile("same.txt")
    main.beginEditingSelectedFile(); main.editSelectedFile("promoted draft"); store.captureFileEditorRecovery(from: main)
    store.moveWorkspaceTabs(from: "task", to: "target"); store.applyTaskSelection(target)
    let migrated = try XCTUnwrap(store.workspaceTabs.first { $0.owner == "target" && $0.kind == .file })
    XCTAssertTrue(store.fileTabWorkspace(migrated) === main)
    store.captureFileEditorRecovery(from: main)
    let record = try XCTUnwrap(store.library.fileEditorRecovery[main.editorKey(for: "same.txt")])
    XCTAssertEqual(record.versions.count, 1); XCTAssertEqual(record.context?.owner, "target")
    let restored = try cold(store), restoredTab = try XCTUnwrap(restored.workspaceTabs.first { $0.kind == .file })
    let editor = restored.fileTabWorkspace(restoredTab); defer { editor.setProject(nil) }
    editor.setProject(root); await editor.openFile("same.txt")
    XCTAssertEqual(editor.fileText, "promoted draft")
  }

  func testCaptureFailureKeepsOtherVersionsAndRetriesWithoutReplacingLiveDraft() async throws {
    let (store, _) = try fixture(); try await competing(store)
    let restored = try cold(store), (_, editor) = try await self.editor(restored, windowID: "first")
    editor.editSelectedFile("first retry")
    let before = restored.library.fileEditorRecovery
    let file = store.dataRoot.appendingPathComponent("workspace.json"), bytes = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    restored.captureFileEditorRecovery(from: editor)
    XCTAssertEqual(restored.library.fileEditorRecovery, before)
    XCTAssertEqual(editor.fileText, "first retry"); XCTAssertNotNil(restored.error)
    try FileManager.default.removeItem(at: file); try bytes.write(to: file, options: .atomic)
    restored.captureFileEditorRecovery(from: editor)
    let versions = try XCTUnwrap(restored.library.fileEditorRecovery[editor.editorKey(for: "same.txt")]).versions
    XCTAssertEqual(Set(versions.map(\.text)), ["first retry", "second draft"])
  }

  func testRecoveryUpdatePreservesUnicodeBytesWithinSameSource() async throws {
    let (store, _) = try fixture(), (_, editor) = try await self.editor(store, windowID: "first")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("\u{e9}")
    store.captureFileEditorRecovery(from: editor)
    editor.editSelectedFile("e\u{301}"); store.captureFileEditorRecovery(from: editor)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    let record = try XCTUnwrap(saved.fileEditorRecovery[editor.editorKey(for: "same.txt")])
    XCTAssertEqual(Array(record.text.utf8), Array("e\u{301}".utf8))
    XCTAssertEqual(record.versions.count, 1)
  }

  func testFailedResolutionKeepsRecordAndRetryResolvesOnlyThatVersion() async throws {
    let (store, _) = try fixture(); try await competing(store)
    let restored = try cold(store), (_, editor) = try await self.editor(restored, windowID: "first")
    let before = restored.library.fileEditorRecovery
    let file = store.dataRoot.appendingPathComponent("workspace.json"), bytes = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    editor.discardSelectedFileEdits()
    XCTAssertEqual(restored.library.fileEditorRecovery, before); XCTAssertNotNil(restored.error)
    try FileManager.default.removeItem(at: file); try bytes.write(to: file, options: .atomic)
    editor.discardSelectedFileEdits(); await editor.openFile("same.txt")
    let saved = try WorkspaceLibrary.load(from: file)
    let versions = try XCTUnwrap(saved.fileEditorRecovery[editor.editorKey(for: "same.txt")]).versions
    XCTAssertEqual(versions.map(\.text), ["second draft"])
    XCTAssertEqual(editor.fileText, "original")
  }

  func testRebindingDoesNotRedirectAnActiveRecoverySelection() async throws {
    let (store, _) = try fixture(); try await competing(store)
    let restored = try cold(store), (_, first) = try await editor(restored, windowID: "first")
    let (_, third) = try await editor(restored, windowID: "third")
    third.editSelectedFile("third draft"); restored.captureFileEditorRecovery(from: third)
    restored.bindFileEditorRecovery(to: first, context: try XCTUnwrap(first.fileEditorRecoveryContext))
    XCTAssertEqual(first.fileText, "first draft")
    first.discardSelectedFileEdits()
    let versions = try XCTUnwrap(restored.library.fileEditorRecovery[first.editorKey(for: "same.txt")]).versions
    XCTAssertEqual(Set(versions.map(\.text)), ["second draft", "third draft"])
  }
}
