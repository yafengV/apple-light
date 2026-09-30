import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class FileContentTabTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, URL, URL) {
    _ = NSApplication.shared
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = base.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "first".write(to: project.appendingPathComponent("First.swift"), atomically: true, encoding: .utf8)
    try "second".write(to: project.appendingPathComponent("Second.swift"), atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.scopeLoaded = true
    store.connected = true
    store.project = project
    store.workspace.setProject(project)
    store.library.tasks = [.init(id: "main", project: project.path, title: "Main", runIDs: []),
      .init(id: "popup", project: project.path, title: "Popup", runIDs: [])]
    store.selection = "main"
    store.restoreWorkspaceTabLayout()
    return (store, base, project)
  }

  func testFileTabsKeepIndependentEditorsAndRestoreExactPaths() async throws {
    let (store, base, project) = try fixture()
    XCTAssertTrue(store.openFileTab("First.swift"))
    let first = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertTrue(store.openFileTab("Second.swift"))
    let second = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(store.visibleWorkspaceContentTabs, [first, second])

    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 880, height: 560),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileWorkspaceTabView(store: store, tab: first,
      openFile: { _ in }, close: {}))
    window.contentView = host
    host.frame.size = .init(width: 880, height: 560)
    func loaded(_ tab: WorkspaceContentTab, _ expected: String) async throws {
      let content = expected == "First.swift" ? "first" : "second"
      for _ in 0..<60 where store.fileTabWorkspace(tab).fileText != content {
        try await Task.sleep(for: .milliseconds(25))
      }
      XCTAssertEqual(store.fileTabWorkspace(tab).selectedFile, expected)
      XCTAssertEqual(store.fileTabWorkspace(tab).fileText, content)
      host.layoutSubtreeIfNeeded()
      func editor(in view: NSView) -> FilePreviewTextView? {
        if let editor = view as? FilePreviewTextView { return editor }
        return view.subviews.compactMap(editor).first
      }
      XCTAssertEqual(try XCTUnwrap(editor(in: host)).string, content)
    }
    try await loaded(first, "First.swift")
    host.rootView = FileWorkspaceTabView(store: store, tab: second, openFile: { _ in }, close: {})
    try await loaded(second, "Second.swift")
    XCTAssertFalse(store.fileTabWorkspace(first) === store.fileTabWorkspace(second))
    XCTAssertEqual(store.fileTabWorkspace(first).fileText, "first")
    XCTAssertEqual(store.workspaceTabTitle(second), "Second.swift")

    store.captureWorkspaceTabLayout()
    store.saveLibrary()
    let restored = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    restored.library = try WorkspaceLibrary.load(from: restored.dataRoot.appendingPathComponent("workspace.json"))
    restored.libraryLoaded = true; restored.scopeLoaded = true; restored.connected = true
    restored.project = project; restored.workspace.setProject(project); restored.selection = "main"
    restored.restoreWorkspaceTabLayout()
    XCTAssertEqual(restored.visibleWorkspaceContentTabs, [first, second])
    XCTAssertEqual(restored.activeWorkspaceContentTab, second)
    XCTAssertEqual(restored.library.workspaceTabLayouts["main"]?.tabs.map(\.filePath), ["First.swift", "Second.swift"])
  }

  func testTaskWindowFileTabStaysWithOwnerAndRestores() throws {
    let (store, _, _) = try fixture()
    let resources = TaskWindowResources()
    defer { resources.shutdown() }
    resources.prepare("popup", store: store)
    let tabs = try XCTUnwrap(resources.tasks["popup"])
    XCTAssertTrue(tabs.openFile("First.swift", in: .right))
    let file = WorkspaceContentTab.file("First.swift", owner: "popup")
    XCTAssertEqual(tabs.selected(.right), file)
    XCTAssertTrue(store.workspaceTabs.isEmpty)
    XCTAssertEqual(store.selection, "main")
    let saved = tabs.layoutSnapshot
    XCTAssertEqual(saved.content.tabs.first?.filePath, "First.swift")

    let restoredResources = TaskWindowResources()
    defer { restoredResources.shutdown() }
    restoredResources.prepare("popup", store: store)
    let restored = try XCTUnwrap(restoredResources.tasks["popup"])
    restored.restoreLayout(saved)
    XCTAssertEqual(restored.selected(.right), file)
  }

  func testPinnedFileTabReopensItsPath() async throws {
    let (store, _, _) = try fixture()
    XCTAssertTrue(store.openFileTab("First.swift"))
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.pinWorkspaceTab(tab.id)
    let pinID = try XCTUnwrap(store.library.pinnedContentTabs.first?.id)
    store.closeWorkspaceTab(tab.id)
    XCTAssertFalse(store.workspaceTabs.contains(tab))
    await store.openPinnedWorkspaceTab(pinID)
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.sourceTabID, tab.id)
  }

  func testReopenFileRestoresItsRightPanelPlacement() throws {
    let (store, _, _) = try fixture()
    XCTAssertTrue(store.openFileTab("First.swift", in: .right))
    let tab = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .right)
    store.closeWorkspaceTab(tab.id)
    XCTAssertFalse(store.workspaceTabs.contains(tab))

    store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeRightWorkspaceContentTab, tab)
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .right)
  }

  func testReopenFileUsesCurrentTasksCloseHistory() throws {
    let (store, _, _) = try fixture()
    XCTAssertTrue(store.openFileTab("First.swift"))
    let main = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.closeWorkspaceTab(main.id)

    store.selection = "popup"
    XCTAssertTrue(store.openFileTab("Second.swift"))
    let popup = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.closeWorkspaceTab(popup.id)

    store.selection = "main"
    XCTAssertTrue(store.canReopenClosedWorkspaceTab)
    store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeWorkspaceContentTab, main)
    store.selection = "popup"
    XCTAssertTrue(store.canReopenClosedWorkspaceTab)
    store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeWorkspaceContentTab, popup)
  }

  func testClosingDirtyFileTabSavesBeforeRemoval() async throws {
    let (store, _, project) = try fixture()
    XCTAssertTrue(store.openFileTab("First.swift"))
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let session = store.fileTabWorkspace(tab)
    session.root = project
    await session.openFile("First.swift")
    session.beginEditingSelectedFile()
    session.editSelectedFile("changed")
    XCTAssertTrue(session.selectedFileEditor?.hasUnsavedChanges == true)
    store.closeWorkspaceTab(tab.id)
    for _ in 0..<60 where store.workspaceTabs.contains(tab) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertFalse(store.workspaceTabs.contains(tab))
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("First.swift"), encoding: .utf8), "changed")
  }

  func testFileTabFindAndLineCommandsTargetItsEditor() async throws {
    let (store, _, project) = try fixture()
    XCTAssertTrue(store.openFileTab("First.swift"))
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let session = store.fileTabWorkspace(tab)
    session.root = project
    await session.openFile("First.swift")
    XCTAssertTrue(store.commandEnabled("browser-address"))
    store.executeCommand("browser-address")
    XCTAssertTrue(session.showingFileLine)
    session.showingFileLine = false
    store.executeCommand("find")
    XCTAssertTrue(session.fileFind.isPresented)
    XCTAssertFalse(store.workspace.fileFind.isPresented)
  }

  func testTaskWindowClosingDirtyFileTabSavesBeforeRemoval() async throws {
    let (store, _, project) = try fixture()
    let resources = TaskWindowResources()
    defer { resources.shutdown() }
    resources.prepare("popup", store: store)
    let tabs = try XCTUnwrap(resources.tasks["popup"])
    XCTAssertTrue(tabs.openFile("First.swift"))
    let tab = try XCTUnwrap(tabs.selected(.left))
    let session = store.fileTabWorkspace(tab)
    session.root = project
    await session.openFile("First.swift")
    session.beginEditingSelectedFile()
    session.editSelectedFile("task change")
    tabs.close(tab.id)
    for _ in 0..<60 where tabs.tabs.contains(tab) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertFalse(tabs.tabs.contains(tab))
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("First.swift"), encoding: .utf8), "task change")
    XCTAssertTrue(store.workspaceTabs.isEmpty)
  }
}
