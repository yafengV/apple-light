import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PrimaryChangeFileIdentityTests: XCTestCase {
  private func fixture(linked: Bool = false) throws -> (WorkspaceStore, URL, URL, URL) {
    _ = NSApplication.shared
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let original = GitBranchService.canonicalRoot(base.appendingPathComponent("Original"))
    let next = GitBranchService.canonicalRoot(base.appendingPathComponent("Next"))
    for root in [original, next] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    try Data("original".utf8).write(to: original.appendingPathComponent("same.txt"))
    try Data("next".utf8).write(to: next.appendingPathComponent("same.txt"))
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.project = original; store.workspace.setProject(original)
    store.library.projects = [original.path]
    if linked { store.library.linkedNewTaskDraftIDs[original.path] = UUID() }
    store.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      for session in store.fileTabWorkspaces.values { session.setProject(nil) }
      try? FileManager.default.removeItem(at: base)
    }
    return (store, base, original, next)
  }

  private func changePrimary(_ store: WorkspaceStore, from original: URL, to next: URL) throws {
    store.beginEditingProject(original.path)
    let request = try XCTUnwrap(store.editingProject)
    try store.saveProjectEdit(request, title: request.title, folders: [original.path], primary: next.path)
    store.editingProject = nil
  }

  private func mount(_ store: WorkspaceStore, tab: WorkspaceContentTab) -> NSWindow {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: FileWorkspaceTabView(store: store, tab: tab, openFile: { _ in }, close: {}))
    window.contentView?.layoutSubtreeIfNeeded()
    return window
  }

  private func settle(_ store: WorkspaceStore, tab: WorkspaceContentTab, text: String) async throws {
    for _ in 0..<80 where store.fileTabWorkspace(tab).fileText != text {
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  func testPrimaryChangeKeepsMountedDirtyFileAndWritesOnlyOriginalForBothDraftKinds() async throws {
    for linked in [false, true] {
      let (store, _, original, next) = try fixture(linked: linked)
      XCTAssertTrue(store.openFileTab("same.txt"))
      let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
      let window = mount(store, tab: tab)
      defer { window.contentView = nil; window.close() }
      try await settle(store, tab: tab, text: "original")
      let session = store.fileTabWorkspace(tab)
      session.beginEditingSelectedFile()
      session.editSelectedFile("edited original")
      try changePrimary(store, from: original, to: next)
      try await Task.sleep(for: .milliseconds(200))
      XCTAssertEqual(store.fileTabWorkspace(tab).root?.path, original.path)
      XCTAssertTrue(store.fileTabWorkspace(tab) === session)
      XCTAssertEqual(store.fileTabWorkspace(tab).selectedFileEditor?.text, "edited original")
      XCTAssertEqual(store.fileTabWorkspace(tab).fileText, "edited original")
      let saved = await store.fileTabWorkspace(tab).saveSelectedFileEdits()
      XCTAssertTrue(saved)
      XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("same.txt"), encoding: .utf8), "edited original")
      XCTAssertEqual(try String(contentsOf: next.appendingPathComponent("same.txt"), encoding: .utf8), "next")
      XCTAssertFalse(window.isVisible)
    }
  }

  func testOpeningSameRelativeNameAfterPrimaryChangeCreatesDistinctFileAndDedupeUsesActualURL() async throws {
    let (store, _, original, next) = try fixture()
    XCTAssertTrue(store.openFileTab("same.txt"))
    let old = try XCTUnwrap(store.activeWorkspaceContentTab)
    try changePrimary(store, from: original, to: next)
    XCTAssertTrue(store.openFileTab("same.txt"))
    let new = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertNotEqual(old.id, new.id)
    XCTAssertEqual(store.workspaceTabs.filter { $0.kind == .file }.count, 2)
    XCTAssertTrue(store.openFileTab(original.appendingPathComponent("same.txt").path))
    XCTAssertEqual(store.activeWorkspaceContentTab, old)
    XCTAssertEqual(store.workspaceTabs.filter { $0.kind == .file }.count, 2)
  }

  func testClosedPinnedFileKeepsOriginalIdentityAfterPrimaryChangeAndLibraryReload() async throws {
    let (store, _, original, next) = try fixture(linked: true)
    XCTAssertTrue(store.openFileTab("same.txt"))
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.pinWorkspaceTab(tab.id)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    store.closeWorkspaceTab(tab.id)
    try changePrimary(store, from: original, to: next)
    XCTAssertTrue(store.saveLibrary())
    let restored = WorkspaceStore(dataRoot: store.dataRoot)
    restored.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    restored.libraryLoaded = true; restored.scopeLoaded = true; restored.connected = true
    restored.project = next; restored.workspace.setProject(next)
    restored.restoreWorkspaceTabLayout()
    defer { restored.workspace.browser.shutdown(); restored.workspace.terminals.shutdown() }
    XCTAssertTrue(restored.openFileTab("same.txt"))
    let new = try XCTUnwrap(restored.activeWorkspaceContentTab)
    XCTAssertEqual(restored.workspaceFileTabURL(new)?.path, next.appendingPathComponent("same.txt").path)
    await restored.openPinnedWorkspaceTab(pin.id)
    let reopened = try XCTUnwrap(restored.activeWorkspaceContentTab)
    XCTAssertNotEqual(new.id, reopened.id)
    XCTAssertEqual(restored.workspaceTabs.filter { $0.kind == .file }.count, 2)
    let window = mount(restored, tab: reopened)
    defer { window.contentView = nil; window.close() }
    try await settle(restored, tab: reopened, text: "original")
    XCTAssertEqual(restored.fileTabWorkspace(reopened).root?.path, original.path)
    XCTAssertEqual(restored.fileTabWorkspace(reopened).fileText, "original")
  }

  func testFailedProjectSaveKeepsLiveFileAndSerializedMetadataUnchanged() throws {
    let (store, _, original, next) = try fixture()
    XCTAssertTrue(store.openFileTab("same.txt"))
    store.pinWorkspaceTab(try XCTUnwrap(store.activeWorkspaceContentTab).id)
    let before = store.library
    let destination = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    XCTAssertThrowsError(try changePrimary(store, from: original, to: next))
    XCTAssertEqual(store.library.workspaceTabLayouts, before.workspaceTabLayouts)
    XCTAssertEqual(store.library.pinnedContentTabs, before.pinnedContentTabs)
    XCTAssertEqual(store.library.primaryFolder(for: original.path), original.path)
  }

  func testLegacyBackgroundDetachedLayoutGetsRootBeforeDefaultChanges() throws {
    let (store, _, original, next) = try fixture()
    let owner = WorkspaceDraftIdentity(project: original.path, linkID: UUID()).owner
    let tab = WorkspaceContentTab.file("same.txt", owner: owner)
    store.library.workspaceTabLayouts[owner] = .init(
      tabs: [.init(id: tab.id, kind: .file, placement: .detached, filePath: "same.txt")],
      showingInspector: false, showingTerminal: false, showingTabs: true, side: .left, reviewScope: .staged)
    try changePrimary(store, from: original, to: next)
    let saved = try XCTUnwrap(store.library.workspaceTabLayouts[owner]?.tabs.first)
    XCTAssertEqual(saved.fileRoot, original.path)
    let restored = WorkspaceStore(dataRoot: store.dataRoot)
    restored.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    restored.libraryLoaded = true; restored.scopeLoaded = true; restored.connected = true; restored.project = next
    let route = WorkspaceTabWindowRoute(tabID: tab.id, owner: owner, dataRoot: restored.dataRoot)
    XCTAssertEqual(restored.detachedWorkspaceTabRestoration(route), .ready(owner))
    XCTAssertEqual(restored.prepareDetachedWorkspaceTab(route), route)
    XCTAssertEqual(restored.workspaceFileTabRoot(tab)?.path, original.path)
  }

  func testInvalidSavedRootsRejectMaterializationAndPinWithoutFallingBackToNewDefault() async throws {
    let (store, _, original, next) = try fixture()
    try changePrimary(store, from: original, to: next)
    let tab = WorkspaceContentTab.file("same.txt", owner: store.draftKey)
    for root in ["relative", "/bad\0root"] {
      let saved = SavedWorkspaceTab(id: tab.id, kind: .file, placement: .left, filePath: "same.txt", fileRoot: root)
      XCTAssertNil(store.materializeWorkspaceTab(saved, owner: tab.owner))
      let pin = PinnedWorkspaceTab(id: UUID().uuidString, sourceTabID: tab.id, owner: tab.owner,
        kind: .file, title: "same.txt", restoreURL: "same.txt", fileRoot: root)
      store.library.pinnedContentTabs = [pin]
      await store.openPinnedWorkspaceTab(pin.id)
      XCTAssertTrue(store.workspaceTabs.isEmpty)
    }
  }

  func testTransferUsesPreservedSourceURLAndUpdatesPinRootAndPath() throws {
    let (store, _, original, next) = try fixture()
    XCTAssertTrue(store.openFileTab("same.txt"))
    let source = try XCTUnwrap(store.activeWorkspaceContentTab); store.pinWorkspaceTab(source.id)
    try changePrimary(store, from: original, to: next)
    store.library.tasks = [.init(id: "target", project: next.path, title: "Target", runIDs: [])]
    let id = try XCTUnwrap(store.moveWorkspaceTab(source.id, toOwner: "target"))
    let moved = try XCTUnwrap(store.workspaceTabs.first { $0.id == id })
    XCTAssertEqual(store.workspaceFileTabURL(moved)?.path, original.appendingPathComponent("same.txt").path)
    XCTAssertEqual(store.workspaceFileTabRoot(moved)?.path, next.path)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.restoreURL, original.appendingPathComponent("same.txt").path)
    XCTAssertEqual(pin.fileRoot, next.path)
    XCTAssertEqual(pin.sourceTabID, id)
  }

  func testTransferRejectsSameFileAlreadyOpenUnderLegacyRelativeID() throws {
    let (store, _, original, next) = try fixture()
    XCTAssertTrue(store.openFileTab("same.txt"))
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)
    try changePrimary(store, from: original, to: next)
    store.library.tasks = [.init(id: "target", project: next.path, title: "Target", runIDs: [])]
    let existing = WorkspaceContentTab.file("same.txt", owner: "target")
    store.workspaceTabs.append(existing); store.workspaceFileTabRoots[existing.id] = original
    XCTAssertNil(store.moveWorkspaceTab(source.id, toOwner: "target"))
    XCTAssertTrue(store.workspaceTabs.contains(source)); XCTAssertTrue(store.workspaceTabs.contains(existing))
  }

  func testActualHelperPrimaryChangeAndRestartRestoreDetachedOriginalFile() async throws {
    let binary = try AgentTestExecutable.url()
    let (_, base, original, next) = try fixture()
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Runtime"), agentExecutable: binary)
    addTeardownBlock { @MainActor in await store.shutdown() }
    await store.restore(); await store.open(original)
    XCTAssertTrue(store.openFileTab("same.txt"))
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.moveWorkspaceTab(tab.id, to: .detached)
    let route = try XCTUnwrap(store.detachedWorkspaceTabRoute(tab.id))
    try changePrimary(store, from: original, to: next)
    await store.newTask(in: original.path)
    XCTAssertEqual(store.project?.path, next.path)
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: store.dataRoot, agentExecutable: binary)
    addTeardownBlock { @MainActor in await restored.shutdown() }
    await restored.restore()
    XCTAssertTrue(restored.connected, restored.error ?? "")
    XCTAssertEqual(restored.project?.path, next.path)
    XCTAssertNotNil(restored.prepareDetachedWorkspaceTab(route))
    let window = mount(restored, tab: tab)
    defer { window.contentView = nil; window.close() }
    try await settle(restored, tab: tab, text: "original")
    XCTAssertEqual(restored.fileTabWorkspace(tab).fileText, "original")
    XCTAssertEqual(restored.fileTabWorkspace(tab).root?.path, original.path)
    await restored.shutdown()
  }


  func testReopenClosedKeepsOldFileWhenNewRootSameNameWasOpenedMeanwhile() async throws {
    let (store, _, original, next) = try fixture()
    XCTAssertTrue(store.openFileTab("same.txt"))
    let old = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.closeWorkspaceTab(old.id)
    try changePrimary(store, from: original, to: next)
    XCTAssertTrue(store.openFileTab("same.txt"))
    let new = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertNotEqual(new.id, old.id)
    store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeWorkspaceContentTab, old)
    XCTAssertEqual(store.workspaceFileTabURL(old)?.path, original.appendingPathComponent("same.txt").path)
    XCTAssertEqual(store.workspaceFileTabURL(new)?.path, next.appendingPathComponent("same.txt").path)
  }

  func testTransferRejectsDuplicateInUnvisitedTargetSavedLayout() throws {
    let (store, _, original, next) = try fixture()
    XCTAssertTrue(store.openFileTab("same.txt"))
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)
    try changePrimary(store, from: original, to: next)
    store.library.tasks = [.init(id: "target", project: next.path, title: "Target", runIDs: [])]
    let existing = WorkspaceContentTab.file("same.txt", owner: "target")
    store.library.workspaceTabLayouts["target"] = .init(tabs: [
      .init(id: existing.id, kind: .file, placement: .right, filePath: "same.txt", fileRoot: original.path)],
      showingInspector: true, showingTerminal: false, showingTabs: true, side: .left, reviewScope: .staged)
    XCTAssertNil(store.moveWorkspaceTab(source.id, toOwner: "target"))
    XCTAssertTrue(store.workspaceTabs.contains(source))
    XCTAssertFalse(store.workspaceTabs.contains(existing))
  }


  func testOpeningAnotherFileFromPreservedTreeUsesItsRootAfterOriginalIsDetachedFromDefaults() throws {
    let (store, _, original, next) = try fixture()
    for (root, value) in [(original, "another original"), (next, "another next")] {
      try Data(value.utf8).write(to: root.appendingPathComponent("another.txt"))
    }
    XCTAssertTrue(store.openFileTab("same.txt"))
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.beginEditingProject(original.path)
    let request = try XCTUnwrap(store.editingProject)
    try store.saveProjectEdit(request, title: request.title, folders: [], primary: next.path)
    store.editingProject = nil
    XCTAssertTrue(store.openFileTab("another.txt", root: store.workspaceFileTabRoot(source)))
    let opened = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertEqual(store.workspaceFileTabURL(opened)?.path, original.appendingPathComponent("another.txt").path)
    XCTAssertEqual(store.workspaceFileTabRoot(opened)?.path, original.path)
  }

}
