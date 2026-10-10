import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowFileIsolationTests: XCTestCase {
  private final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private func fixture() throws -> (WorkspaceStore, URL, URL, URL, WorkspaceContentTab) {
    _ = NSApplication.shared
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let original = GitBranchService.canonicalRoot(base.appendingPathComponent("Original"))
    let next = GitBranchService.canonicalRoot(base.appendingPathComponent("Next"))
    for root in [original, next] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    try Data("original".utf8).write(to: original.appendingPathComponent("same.txt"))
    try Data("next".utf8).write(to: next.appendingPathComponent("same.txt"))
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.project = original; store.workspace.setProject(original); store.library.projects = [original.path]
    store.restoreWorkspaceTabLayout()
    XCTAssertTrue(store.openFileTab("same.txt"))
    let owner = store.draftKey
    store.beginEditingProject(original.path)
    let request = try XCTUnwrap(store.editingProject)
    try store.saveProjectEdit(request, title: request.title, folders: [original.path], primary: next.path)
    store.editingProject = nil
    store.library.tasks = [.init(id: "task", project: next.path, title: "Task", runIDs: [])]
    store.moveWorkspaceTabs(from: owner, to: "task")
    store.project = next; store.workspace.setProject(next); store.applyTaskSelection(store.library.tasks[0])
    let tab = try XCTUnwrap(store.workspaceTabs.first { $0.kind == .file })
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      for session in store.fileTabWorkspaces.values { session.setProject(nil) }
      try? FileManager.default.removeItem(at: base)
    }
    return (store, base, original, next, tab)
  }

  private func window(_ root: some View, receivesKeys: Bool = false) -> NSWindow {
    let type: NSWindow.Type = receivesKeys ? KeyWindow.self : NSWindow.self
    let window = type.init(contentRect: .init(x: 0, y: 0, width: 1050, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: root)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
  }

  private func fileView(_ view: NSView?) -> FilePreviewTextView? {
    guard let view else { return nil }
    if let found = view as? FilePreviewTextView { return found }
    return view.subviews.lazy.compactMap { self.fileView($0) }.first
  }

  private func taskWindow(_ store: WorkspaceStore, resources: TaskWindowResources, tabs: TaskWindowTabs, receivesKeys: Bool = false) -> NSWindow {
    window(TaskWindowView(store: store, taskID: "task", tabs: tabs, resources: resources,
      renameHistory: TaskRenameHistory(), onNavigate: { _ in }, canGoBack: false, canGoForward: false, onMove: { _ in }), receivesKeys: receivesKeys)
  }

  private func settle(_ window: NSWindow, text: String) async throws -> DeveloperWorkspace {
    for _ in 0..<80 where fileView(window.contentView)?.workspace?.fileText != text {
      try await Task.sleep(for: .milliseconds(25)); window.contentView?.layoutSubtreeIfNeeded()
    }
    return try XCTUnwrap(fileView(window.contentView)?.workspace)
  }

  func testActualTaskPageUsesItsExecutionRootAndClosingSavesOnlyItsOwnFile() async throws {
    let (store, _, original, next, mainTab) = try fixture()
    let mainWindow = window(FileWorkspaceTabView(store: store, tab: mainTab, openFile: { _ in }, close: {}))
    defer { mainWindow.contentView = nil; mainWindow.close() }
    let main = try await settle(mainWindow, text: "original")
    main.beginEditingSelectedFile(); main.editSelectedFile("main draft")
    let resources = TaskWindowResources(); resources.prepare("task", store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile("same.txt"))
    let childTab = try XCTUnwrap(tabs.selected(.left)); XCTAssertEqual(childTab.id, mainTab.id)
    let childWindow = taskWindow(store, resources: resources, tabs: tabs)
    defer { childWindow.contentView = nil; childWindow.close() }
    let child = try await settle(childWindow, text: "next")
    XCTAssertEqual(child.root?.path, next.path)
    XCTAssertEqual(child.fileText, "next")
    XCTAssertFalse(child === main)
    XCTAssertEqual(main.root?.path, original.path); XCTAssertEqual(main.fileText, "main draft")
    child.beginEditingSelectedFile(); child.editSelectedFile("child saved")
    tabs.close(childTab.id)
    XCTAssertTrue(tabs.tabs.contains(childTab))
    XCTAssertEqual(child.fileCloseRequest, "same.txt")
    XCTAssertEqual(try String(contentsOf: next.appendingPathComponent("same.txt"), encoding: .utf8), "next")
    let saved = await child.saveAndCloseRequestedFile()
    XCTAssertTrue(saved)
    tabs.close(childTab.id)
    XCTAssertFalse(tabs.tabs.contains(childTab))
    XCTAssertEqual(try String(contentsOf: next.appendingPathComponent("same.txt"), encoding: .utf8), "child saved")
    XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("same.txt"), encoding: .utf8), "original")
    XCTAssertTrue(store.workspaceTabs.contains(mainTab)); XCTAssertEqual(main.fileText, "main draft")
    XCTAssertFalse(mainWindow.isVisible); XCTAssertFalse(childWindow.isVisible)
  }

  func testTwoActualTaskPagesKeepFileFindAndViewStateIndependent() async throws {
    let (store, _, _, _, _) = try fixture()
    let firstResources = TaskWindowResources(), secondResources = TaskWindowResources()
    firstResources.prepare("task", store: store); secondResources.prepare("task", store: store)
    defer { firstResources.shutdown(); secondResources.shutdown() }
    let firstTabs = try XCTUnwrap(firstResources.tasks["task"]), secondTabs = try XCTUnwrap(secondResources.tasks["task"])
    XCTAssertTrue(firstTabs.openFile("same.txt")); XCTAssertTrue(secondTabs.openFile("same.txt"))
    let firstWindow = taskWindow(store, resources: firstResources, tabs: firstTabs, receivesKeys: true)
    let secondWindow = taskWindow(store, resources: secondResources, tabs: secondTabs)
    defer { firstWindow.contentView = nil; firstWindow.close(); secondWindow.contentView = nil; secondWindow.close() }
    let first = try await settle(firstWindow, text: "next"), second = try await settle(secondWindow, text: "next")
    XCTAssertFalse(first === second)
    try await Task.sleep(for: .milliseconds(100))
    for (character, keyCode) in [("f", UInt16(3)), ("l", UInt16(37))] {
      NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.command], timestamp: 0, windowNumber: firstWindow.windowNumber,
        context: nil, characters: character, charactersIgnoringModifiers: character,
        isARepeat: false, keyCode: keyCode)))
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(first.fileFind.isPresented); XCTAssertTrue(first.showingFileLine)
    XCTAssertFalse(second.fileFind.isPresented); XCTAssertFalse(second.showingFileLine)
    XCTAssertFalse(firstWindow.isVisible); XCTAssertFalse(secondWindow.isVisible)
  }

  func testTaskWindowPinAndSavedLayoutCarryWindowRootInsteadOfMainLegacyRoot() throws {
    let (store, _, original, next, mainTab) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("task", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile("same.txt"))
    let tab = try XCTUnwrap(tabs.selected(.left)); XCTAssertEqual(tab.id, mainTab.id)
    resources.pin(tab.id, taskID: "task")
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.fileRoot, next.path)
    XCTAssertEqual(tabs.layoutSnapshot.content.tabs.first?.fileRoot, next.path)
    XCTAssertEqual(store.workspaceFileTabRoot(mainTab)?.path, original.path)
  }

  func testClosingWindowPersistsBothRootsWithoutClearingMainEditor() async throws {
    let (store, _, original, next, mainTab) = try fixture()
    let main = store.fileTabWorkspace(mainTab)
    main.setProject(original); await main.openFile("same.txt")
    main.beginEditingSelectedFile(); main.editSelectedFile("main recovery")
    let resources = TaskWindowResources(); resources.prepare("task", store: store)
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile("same.txt"))
    let child = resources.fileWorkspace(try XCTUnwrap(tabs.focused))
    child.setProject(next); await child.openFile("same.txt")
    child.beginEditingSelectedFile(); child.editSelectedFile("child recovery")
    resources.shutdown()
    XCTAssertNil(child.root)
    XCTAssertEqual(main.root, original); XCTAssertEqual(main.fileText, "main recovery")
    store.captureFileEditorRecovery(from: main)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.fileEditorRecovery[original.appendingPathComponent("same.txt").path]?.text, "main recovery")
    XCTAssertEqual(saved.fileEditorRecovery[next.appendingPathComponent("same.txt").path]?.text, "child recovery")
    XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("same.txt"), encoding: .utf8), "original")
    XCTAssertEqual(try String(contentsOf: next.appendingPathComponent("same.txt"), encoding: .utf8), "next")
  }

  func testPendingCloseCannotRemoveNewEditorAfterTaskChangesRoot() async throws {
    let (store, _, original, next, _) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("task", store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile("same.txt"))
    let oldTab = try XCTUnwrap(tabs.focused), old = resources.fileWorkspace(oldTab)
    old.setProject(next); await old.openFile("same.txt")
    old.beginEditingSelectedFile(); old.editSelectedFile("keep old pending draft")
    tabs.close(oldTab.id)
    XCTAssertTrue(tabs.tabs.contains(oldTab), "The dirty close must await its save")
    store.library.tasks[0].project = original.path
    resources.prepare("task", store: store)
    XCTAssertTrue(tabs.openFile("same.txt"))
    let replacementTab = try XCTUnwrap(tabs.focused), replacement = resources.fileWorkspace(replacementTab)
    XCTAssertEqual(replacementTab.id, oldTab.id); XCTAssertFalse(replacement === old)
    replacement.setProject(original); await replacement.openFile("same.txt")
    for _ in 0..<8 { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(tabs.tabs.contains(replacementTab))
    XCTAssertEqual(replacement.fileText, "original")
    XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("same.txt"), encoding: .utf8), "original")
    XCTAssertEqual(store.library.fileEditorRecovery[next.appendingPathComponent("same.txt").path]?.text, "keep old pending draft")
  }

  func testOldPinCannotRetargetSameRelativeIDAfterWindowRootChanges() async throws {
    let (store, _, original, next, mainTab) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("task", store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile("same.txt"))
    resources.pin(try XCTUnwrap(tabs.focusedID), taskID: "task")
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertTrue(resources.contains(pin))
    store.library.tasks[0].project = original.path
    resources.prepare("task", store: store)
    XCTAssertTrue(tabs.openFile("same.txt")); XCTAssertEqual(tabs.focusedID, pin.sourceTabID)
    XCTAssertFalse(resources.contains(pin))
    resources.capturePins()
    XCTAssertEqual(store.library.pinnedContentTabs.first?.fileRoot, next.path)
    store.project = original; store.workspace.setProject(original); store.applyTaskSelection(store.library.tasks[0])
    await store.openPinnedWorkspaceTab(pin.id)
    let restored = try XCTUnwrap(store.library.pinnedContentTabs.first)
    let active = try XCTUnwrap(store.focusedWorkspaceContentTab)
    XCTAssertNil(restored.sourceWindowID)
    XCTAssertEqual(store.workspaceFileTabRoot(active)?.path, next.path)
    XCTAssertNotEqual(active.id, mainTab.id)
    XCTAssertEqual(store.workspaceFileTabRoot(mainTab)?.path, original.path)
  }

  func testColdActualTaskPageRestoresWindowRootAndRecoveryIndependently() async throws {
    let (store, _, original, next, mainTab) = try fixture()
    let source = TaskWindowResources(); source.prepare("task", store: store, windowID: "durable-window")
    let tabs = try XCTUnwrap(source.tasks["task"]); XCTAssertTrue(tabs.openFile("same.txt"))
    source.pin(try XCTUnwrap(tabs.focusedID), taskID: "task")
    let child = source.fileWorkspace(try XCTUnwrap(tabs.focused))
    child.setProject(next); await child.openFile("same.txt")
    child.beginEditingSelectedFile(); child.editSelectedFile("cold child draft")
    source.shutdown()
    let cold = WorkspaceStore(dataRoot: store.dataRoot)
    cold.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    cold.libraryLoaded = true; cold.scopeLoaded = true; cold.connected = true
    cold.project = next; cold.workspace.setProject(next); cold.applyTaskSelection(cold.library.tasks[0])
    defer { cold.workspace.browser.shutdown(); cold.workspace.terminals.shutdown() }
    let restored = TaskWindowResources(); restored.prepare("task", store: cold, windowID: "durable-window")
    defer { restored.shutdown() }
    let result = try XCTUnwrap(restored.tasks["task"]), file = try XCTUnwrap(result.focused)
    XCTAssertEqual(file.id, mainTab.id)
    XCTAssertTrue(restored.contains(try XCTUnwrap(cold.library.pinnedContentTabs.first)))
    let native = taskWindow(cold, resources: restored, tabs: result)
    defer { native.contentView = nil; native.close() }
    let editor = try await settle(native, text: "cold child draft")
    XCTAssertEqual(editor.root?.path, next.path); XCTAssertEqual(editor.fileText, "cold child draft")
    XCTAssertEqual(editor.selectedFileEditor?.baseText, "next")
    XCTAssertEqual(cold.workspaceFileTabRoot(mainTab)?.path, original.path)
    XCTAssertEqual(try String(contentsOf: next.appendingPathComponent("same.txt"), encoding: .utf8), "next")
  }

  func testSavedFileRootRejectsDifferentOrMalformedRootsButAcceptsLegacyLayout() throws {
    let (store, _, original, next, _) = try fixture()
    let source = TaskWindowResources(); source.prepare("task", store: store)
    defer { source.shutdown() }
    let tabs = try XCTUnwrap(source.tasks["task"]); XCTAssertTrue(tabs.openFile("same.txt"))
    let valid = tabs.layoutSnapshot
    for root in [original.path, "relative", "\0invalid", next.path] {
      var saved = valid; saved.content.tabs[0].fileRoot = root
      let resources = TaskWindowResources(); resources.prepare("task", store: store)
      defer { resources.shutdown() }
      let target = try XCTUnwrap(resources.tasks["task"]); target.restoreLayout(saved)
      XCTAssertEqual(target.tabs.count, root == next.path ? 1 : 0, "Saved root: \(root.debugDescription)")
    }
    var legacy = valid; legacy.content.tabs[0].fileRoot = nil
    let resources = TaskWindowResources(); resources.prepare("task", store: store)
    defer { resources.shutdown() }
    let target = try XCTUnwrap(resources.tasks["task"]); target.restoreLayout(legacy)
    XCTAssertEqual(target.tabs.count, 1)
  }

  func testEmptyFileChooserPinRecognizesCanonicalRootAndDoesNotRetarget() throws {
    let (store, _, original, next, _) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("task", store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile(""))
    resources.pin(try XCTUnwrap(tabs.focusedID), taskID: "task")
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.fileRoot, next.path)
    XCTAssertTrue(resources.contains(pin))
    store.library.tasks[0].project = original.path
    resources.prepare("task", store: store); XCTAssertTrue(tabs.openFile(""))
    XCTAssertFalse(resources.contains(pin)); resources.capturePins()
    XCTAssertEqual(store.library.pinnedContentTabs.first?.fileRoot, next.path)
  }
}
