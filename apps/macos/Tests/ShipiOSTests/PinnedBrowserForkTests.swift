import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class PinnedBrowserForkTests: XCTestCase {
  private func translated(_ key: String) throws -> String {
    let file = try XCTUnwrap(Bundle.module.url(forResource: "pinned_browser_fork_menu_reference_725",
      withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    return try XCTUnwrap(reference["translations"]["threadHeader." + key].text)
  }
  func testActualReferenceSubmenuOrderOwnerAndPostForkNavigation() throws {
    let file = try XCTUnwrap(Bundle.module.url(forResource: "pinned_browser_fork_menu_reference_725",
      withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    let samples = try reference["cases"].decode([JSONValue].self)
    XCTAssertEqual(samples.count, 11)
    for sample in samples {
      let items = try sample["items"].decode([JSONValue].self)
      let ids = items.compactMap { $0["id"].text }
      let forks = try sample["forks"].decode([JSONValue].self)
      XCTAssertEqual(try sample["staleCallbacks"].decode([JSONValue].self).count, 0)
      guard sample["fork"].boolean == true else { XCTAssertTrue(forks.isEmpty); continue }
      let index = try XCTUnwrap(ids.firstIndex(of: "fork-browser-tab"))
      XCTAssertEqual(ids[index - 1], PinnedBrowserAction.duplicate.rawValue)
      XCTAssertEqual(ids[index + 1], PinnedBrowserAction.copyURL.rawValue)
      let submenu = try items[index]["submenu"].decode([JSONValue].self)
      let expected: [PinnedBrowserForkDestination] = sample["name"].text == "forkable-projectless"
        ? [.currentWorkspace] : [.currentWorkspace, .newWorktree]
      XCTAssertEqual(submenu.compactMap { $0["id"].text }, expected.map(\.rawValue))
      XCTAssertEqual(submenu.first?["title"].text,
        sample["worktree"].boolean == true ? "Fork chat in same worktree" : "Fork chat")
      for fork in forks {
        let calls = try fork["calls"].decode([JSONValue].self)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0]["args"]["sourceConversationId"].text, "a")
        XCTAssertEqual(calls[0]["args"]["sourceWorkspaceRoot"].text,
          sample["name"].text == "forkable-projectless" ? "~" : "/a")
        XCTAssertEqual(calls[1]["args"]["type"].text, "navigate-to-route")
        XCTAssertEqual(calls[1]["args"]["path"].text,
          fork["id"].text == PinnedBrowserForkDestination.newWorktree.rawValue ? "/local/pending-child" : "fork-child")
      }
    }
  }

  private func fixture(project: URL? = nil, taskWindow: Bool = false) async throws
    -> (WorkspaceStore, PinnedBrowserActionContext, TaskWindowResources?) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-fork-\(UUID())")
    let store = WorkspaceStore(dataRoot: root, agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    if let project { await store.open(project); store.library.visit(project.path) }
    store.modelConfiguration.model = ""; store.modelConfiguration.baseURL = ""
    let path = project?.path ?? ""
    store.library.tasks = [.init(id: "source", project: path, title: "Source", runIDs: ["finished", "active"]),
      .init(id: "displayed", project: path, title: "Displayed", runIDs: [])]
    store.library.chatRuns = ["finished", "active"].map {
      .init(id: $0, kind: "chat", project: path, status: $0 == "active" ? "running" : "succeeded",
        createdAt: 1, updatedAt: 2, request: .null, result: .object(["response": .string("reply-" + $0)]))
    }
    store.library.notes["finished"] = "completed source prompt"
    store.library.drafts = ["source": "source draft", "displayed": "displayed draft"]
    store.applyTaskSelection(store.library.tasks[0])
    let resources: TaskWindowResources?
    if taskWindow {
      let owner = TaskWindowResources(); owner.prepare("source", store: store, windowID: "source-window")
      owner.display("source")
      let tabs = try XCTUnwrap(owner.tasks["source"]); tabs.newBrowser(in: .right)
      owner.pin(try XCTUnwrap(tabs.focusedID), taskID: "source"); resources = owner
    } else {
      store.newBrowserTab(in: .right)
      store.pinWorkspaceTab(try XCTUnwrap(store.focusedWorkspaceContentTab?.id)); resources = nil
    }
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    store.applyTaskSelection(store.library.tasks[1])
    let context = try XCTUnwrap(store.pinnedBrowserActionContext(pin.id))
    addTeardownBlock { @MainActor in
      resources?.shutdown(); await store.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return (store, context, resources)
  }

  func testBothLiveSourceContainersForkTheirOwnerAndNavigateToSavedChild() async throws {
    for window in [false, true] {
      let (store, context, resources) = try await fixture(taskWindow: window)
      XCTAssertEqual(store.pinnedBrowserForkDestinations(context), [.currentWorkspace])
      XCTAssertEqual(store.pinnedBrowserForkTitle(.currentWorkspace, context: context), try translated("forkIntoLocal"))
      XCTAssertEqual(store.pinnedBrowserForkTitle(.newWorktree, context: context), try translated("forkIntoWorktree"))
      let created = await store.forkPinnedBrowser(context, to: .currentWorkspace)
      let child = try XCTUnwrap(created, store.error ?? "")
      XCTAssertEqual(child.forkOrigin?.taskID, "source")
      XCTAssertEqual(child.forkOrigin?.runID, "finished")
      XCTAssertEqual(store.library.chatContext(taskID: child.id).map(\.content), ["completed source prompt", "reply-finished"])
      XCTAssertEqual(store.selectedTask?.id, child.id)
      XCTAssertEqual(store.library.drafts["displayed"], "displayed draft")
      XCTAssertEqual(store.library.drafts["source"], "source draft")
      XCTAssertEqual(store.activeRun(taskID: "source")?.id, "active")
      XCTAssertFalse(context.page.closed)
      XCTAssertTrue(context.session.tabs.contains { $0 === context.page })
      if let resources { XCTAssertEqual(resources.displayedTaskID, "source") }
      let disk = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      XCTAssertEqual(disk.tasks.first?.id, child.id)
    }
  }

  func testStaleModalReservedAndDuplicateCallbacksCannotCreateForks() async throws {
    for mutation in 0..<6 {
      let (store, context, _) = try await fixture()
      switch mutation {
      case 0: store.unpinWorkspaceTab(context.pin.id)
      case 1: context.session.close(context.page.id)
      case 2: store.showingModelPicker = true
      case 3: store.activityArchivingTaskIDs = ["source"]
      case 4: store.taskMenuForkingID = "source"
      default: store.library.tasks[0].archived = true
      }
      XCTAssertTrue(store.pinnedBrowserForkDestinations(context).isEmpty)
      let result = await store.forkPinnedBrowser(context, to: .currentWorkspace)
      XCTAssertNil(result); XCTAssertEqual(store.library.tasks.count, 2)
      XCTAssertEqual(store.selectedTask?.id, "displayed")
      store.showingModelPicker = false; store.taskMenuForkingID = nil; store.activityArchivingTaskIDs = []
    }
  }

  func testFailedPersistenceKeepsSourceAndAllowsSameLiveMenuRetry() async throws {
    let (store, context, _) = try await fixture()
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let failed = await store.forkPinnedBrowser(context, to: .currentWorkspace)
    XCTAssertNil(failed); XCTAssertEqual(store.selectedTask?.id, "displayed")
    XCTAssertEqual(store.library.tasks.count, 2); XCTAssertNil(store.taskMenuForkingID)
    try FileManager.default.removeItem(at: file)
    let retried = await store.forkPinnedBrowser(context, to: .currentWorkspace)
    XCTAssertNotNil(retried); XCTAssertEqual(store.selectedTask?.id, retried?.id)
  }

  func testGitSourceForksIntoNewCheckoutThenOffersSameWorktreeRoute() async throws {
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("browser-fork-git-\(UUID())"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q"], at: root)
    _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: root)
    _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: root)
    try Data("initial\n".utf8).write(to: root.appendingPathComponent("tracked"))
    _ = try await GitReviewService.checked(["add", "."], at: root)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: root)
    try Data("uncommitted\n".utf8).write(to: root.appendingPathComponent("tracked"))
    let (store, context, _) = try await fixture(project: root)
    store.library.newTaskEnvironmentSelections[root.path] = WorktreeEnvironmentChoice.none
    XCTAssertEqual(store.pinnedBrowserForkDestinations(context), [.currentWorkspace, .newWorktree])
    let status = try await GitReviewService.checked(["status", "--porcelain=v1", "-z"], at: root)
    let created = await store.forkPinnedBrowser(context, to: .newWorktree)
    let child = try XCTUnwrap(created, store.error ?? store.worktreeError ?? "")
    XCTAssertNotEqual(child.project, root.path)
    XCTAssertEqual(store.selectedTask?.id, child.id)
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: child.project).appendingPathComponent("tracked")), "uncommitted\n")
    let after = try await GitReviewService.checked(["status", "--porcelain=v1", "-z"], at: root)
    XCTAssertEqual(after, status)
    XCTAssertEqual(store.library.tasks.first { $0.id == "source" }?.project, root.path)
    XCTAssertEqual(store.library.drafts["source"], "source draft")
    store.newBrowserTab(in: .right)
    store.pinWorkspaceTab(try XCTUnwrap(store.focusedWorkspaceContentTab?.id))
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first { $0.owner == child.id })
    let childContext = try XCTUnwrap(store.pinnedBrowserActionContext(pin.id))
    XCTAssertEqual(store.pinnedBrowserForkTitle(.currentWorkspace, context: childContext), try translated("forkIntoSameWorktree"))
    let sameCheckout = await store.forkPinnedBrowser(childContext, to: .currentWorkspace)
    let second = try XCTUnwrap(sameCheckout)
    XCTAssertEqual(second.project, child.project)
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    XCTAssertEqual(store.library.managedWorktree(forTaskID: second.id)?.path, child.project)
  }
}
