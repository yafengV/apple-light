import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class LinkedDraftWorkspaceTests: XCTestCase {
  private func fixture(project: Bool = true, name: String = "Project") throws -> (WorkspaceStore, URL, String) {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = GitBranchService.canonicalRoot(directory)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = project
    if project { store.project = root; store.workspace.setProject(root); store.library.projects = [root.path] }
    store.library.tasks = [.init(id: "task", project: project ? root.path : "", title: "Task", runIDs: [])]
    store.library.linkedNewTaskDraftIDs[project ? root.path : ""] = UUID()
    let owner = store.draftKey
    store.library.drafts[owner] = "linked draft"
    store.library.drafts[project ? "new:\(root.path)" : "new:none"] = "ordinary draft"
    store.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
    return (store, root, owner)
  }

  func testLinkedProjectFileAndReviewUseActualDirectory() async throws {
    let (store, root, owner) = try fixture()
    try Data("linked file".utf8).write(to: root.appendingPathComponent("file.txt"))
    XCTAssertEqual(store.workspaceTabProject(owner: owner), root)
    XCTAssertTrue(store.openFileTab("file.txt"), store.error ?? "")
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertEqual(tab.owner, owner)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
    let host = NSHostingView(rootView: FileWorkspaceTabView(store: store, tab: tab, openFile: { _ in }, close: {}))
    window.contentView = host; host.layoutSubtreeIfNeeded()
    for _ in 0..<60 where store.fileTabWorkspace(tab).fileText != "linked file" { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertEqual(store.fileTabWorkspace(tab).selectedFileEditor?.text, "linked file")
    XCTAssertFalse(window.isVisible)
    let review = DetachedReviewSession(); defer { review.shutdown() }
    review.configure(store: store, owner: owner)
    XCTAssertEqual(review.workspace.root, root)
  }

  func testLinkedTerminalFallbackAndColdRestorationUseActualDirectory() throws {
    let (store, root, owner) = try fixture()
    let tab = WorkspaceContentTab.terminal(UUID(), owner: owner)
    XCTAssertEqual(store.terminalScope(for: tab), TerminalScope(root: root, conversation: owner))
    let saved = SavedWorkspaceTab(id: tab.id, kind: .terminal, placement: .bottom)
    XCTAssertEqual(store.materializeWorkspaceTab(saved, owner: owner), tab)
    let session = try XCTUnwrap(store.terminalSession(try XCTUnwrap(tab.terminalID)))
    XCTAssertEqual(store.terminalScope(for: tab)?.root.path, root.path)
    XCTAssertTrue(session.view.process.running)
  }

  func testLinkedProjectlessDraftHasNoFileOrTerminalDirectory() throws {
    let (store, _, owner) = try fixture(project: false)
    XCTAssertNil(store.workspaceTabProject(owner: owner))
    XCTAssertNil(store.terminalScope(for: .terminal(UUID(), owner: owner)))
  }

  func testCommandBrowserReturnsToExactLinkedDraftWithoutClearingOrdinaryDraft() async throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      let (store, _, owner) = try fixture(project: false)
      store.newBrowserTab(in: mode == .full ? .left : .right)
      let result = try XCTUnwrap(store.commandBrowserTabs.first)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      store.applyTaskSelection(store.library.tasks[0]); store.draft = "task draft"
      let opened = await store.openCommandBrowserTab(result)
      XCTAssertTrue(opened, store.error ?? "")
      XCTAssertEqual(store.draftKey, owner); XCTAssertEqual(store.draft, "linked draft")
      XCTAssertEqual(store.library.drafts["new:none"], "ordinary draft")
      XCTAssertEqual(store.library.drafts["task"], "task draft")
      XCTAssertTrue(store.workspace.browser.selected === page)
      XCTAssertEqual(store.focusedWorkspaceTabID, result.id)
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, mode)
      XCTAssertFalse(page.closed)
    }
  }

  func testDetachedChatReturnsToExactLinkedDraftAndKeepsDetachedContent() async throws {
    let (store, _, owner) = try fixture(project: false)
    store.newBrowserTab(); let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.moveWorkspaceTab(tab.id, to: .detached)
    store.applyTaskSelection(store.library.tasks[0])
    let opened = await store.focusDetachedWorkspaceChat(tab.id)
    XCTAssertTrue(opened, store.error ?? "")
    XCTAssertEqual(store.draftKey, owner); XCTAssertEqual(store.draft, "linked draft")
    XCTAssertEqual(store.library.drafts["new:none"], "ordinary draft")
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .detached)
    XCTAssertNil(store.focusedWorkspaceContentTab)
  }

  func testPinnedContentReturnsToExistingLinkedDraft() async throws {
    let (store, _, owner) = try fixture(project: false)
    store.newBrowserTab(); let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.pinWorkspaceTab(tab.id)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    store.applyTaskSelection(store.library.tasks[0])
    await store.openPinnedWorkspaceTab(pin.id)
    XCTAssertEqual(store.draftKey, owner); XCTAssertEqual(store.draft, "linked draft")
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.sourceTabID, tab.id)
  }
  func testBackAndForwardPreserveLinkedAndOrdinaryDraftIdentities() async throws {
    let (store, _, owner) = try fixture(project: false)
    store.newBrowserTab(in: .right)
    let browser = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    store.newTask()
    XCTAssertEqual(store.draftKey, "new:none"); XCTAssertEqual(store.draft, "ordinary draft")
    await store.navigate(back: true)
    XCTAssertEqual(store.draftKey, owner); XCTAssertEqual(store.draft, "linked draft")
    XCTAssertEqual(store.activeRightWorkspaceContentTab, browser)
    await store.navigate(back: false)
    XCTAssertEqual(store.draftKey, "new:none"); XCTAssertEqual(store.draft, "ordinary draft")
    XCTAssertTrue(store.workspaceTabs.contains(browser))
  }

  func testInvalidDraftOwnersCannotResolveRelativeDirectoriesOrOpenScopes() async throws {
    let (store, _, owner) = try fixture(project: false)
    for invalid in ["new:", "new:relative", "new:none:link:invalid", "new:/bad\0path", "task"] {
      XCTAssertNil(store.workspaceDraftIdentity(owner: invalid), invalid)
      let opened = await store.selectWorkspaceDraft(invalid)
      XCTAssertFalse(opened, invalid); XCTAssertEqual(store.draftKey, owner)
    }
  }

  func testPrimaryFolderAndLiteralLinkDelimiterRemainDistinctFromNonce() throws {
    let (store, root, _) = try fixture(name: "Project:link:\(UUID().uuidString)")
    let plain = "new:\(root.path)"
    XCTAssertEqual(store.workspaceDraftIdentity(owner: plain)?.project, root.path)
    XCTAssertNil(store.workspaceDraftIdentity(owner: plain)?.linkID)
    let alternate = root.deletingLastPathComponent().appendingPathComponent("Primary")
    try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
    store.library.projectPrimaryFolders[root.path] = alternate.path
    store.library.projectScopeOwners[alternate.path] = root.path
    XCTAssertEqual(store.workspaceTabProject(owner: plain)?.path, alternate.path)
    XCTAssertEqual(store.workspaceTabProject(owner: store.draftKey)?.path, alternate.path)
  }

  func testActualDeepLinksKeepMultipleDraftContentsAcrossProjectsAndRestart() async throws {
    let binary = try AgentTestExecutable.url()
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = base.appendingPathComponent("First"), second = base.appendingPathComponent("Second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data("deep link file".utf8).write(to: first.appendingPathComponent("file.txt"))
    addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"), agentExecutable: binary)
    addTeardownBlock { @MainActor in await store.shutdown() }
    await store.restore(); await store.open(first); store.draft = "ordinary first"
    await store.openDeepLink(.newTask(prompt: "first link", path: first.path, originURL: nil))
    let firstOwner = store.draftKey
    XCTAssertEqual(store.workspaceTabProject(owner: firstOwner)?.path, first.path)
    XCTAssertTrue(store.openFileTab("file.txt"))
    let file = try XCTUnwrap(store.activeWorkspaceContentTab); store.pinWorkspaceTab(file.id)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    store.newBrowserTab(in: .right)
    let browser = try XCTUnwrap(store.commandBrowserTabs.first)
    let page = try XCTUnwrap(store.workspace.browser.selected)
    await store.openDeepLink(.newTask(prompt: "second link", path: first.path, originURL: nil))
    let secondOwner = store.draftKey
    XCTAssertNotEqual(firstOwner, secondOwner)
    let reopened = await store.openCommandBrowserTab(browser)
    XCTAssertTrue(reopened, store.error ?? ""); XCTAssertEqual(store.draftKey, firstOwner)
    XCTAssertEqual(store.library.drafts[secondOwner], "second link")
    XCTAssertEqual(store.library.drafts["new:\(first.path)"], "ordinary first")
    XCTAssertTrue(store.workspace.browser.selected === page)
    await store.openDeepLink(.newTask(prompt: "other project link", path: second.path, originURL: nil))
    let otherOwner = store.draftKey
    await store.openPinnedWorkspaceTab(pin.id)
    XCTAssertEqual(store.project?.path, first.path); XCTAssertEqual(store.draftKey, firstOwner)
    XCTAssertEqual(store.activeRightWorkspaceContentTab, file)
    XCTAssertNil(store.activeWorkspaceContentTab)
    XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
    XCTAssertEqual(store.focusedWorkspaceContentTab, file)
    XCTAssertEqual(store.library.drafts[otherOwner], "other project link")
    await store.shutdown()

    let restored = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"), agentExecutable: binary)
    addTeardownBlock { @MainActor in await restored.shutdown() }
    await restored.restore()
    XCTAssertTrue(restored.connected, restored.error ?? "")
    XCTAssertEqual(restored.draftKey, firstOwner); XCTAssertEqual(restored.draft, "first link")
    XCTAssertEqual(restored.activeRightWorkspaceContentTab, file)
    XCTAssertNil(restored.activeWorkspaceContentTab)
    XCTAssertEqual(restored.effectiveWorkspaceContentLayoutMode, .split)
    XCTAssertEqual(restored.focusedWorkspaceContentTab, file)
    XCTAssertEqual(restored.library.drafts[secondOwner], "second link")
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
    let host = NSHostingView(rootView: AppContentView(store: restored)); window.contentView = host
    host.layoutSubtreeIfNeeded()
    for _ in 0..<80 where restored.fileTabWorkspace(file).fileText != "deep link file" { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertEqual(restored.fileTabWorkspace(file).selectedFileEditor?.text, "deep link file")
    XCTAssertFalse(window.isVisible)
    await restored.shutdown()
  }

}
