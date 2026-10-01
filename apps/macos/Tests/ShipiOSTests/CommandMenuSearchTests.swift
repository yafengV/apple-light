import XCTest
@testable import ShipiOS

final class CommandMenuSearchTests: XCTestCase {
  private func task(_ id: String, updated: Double = 1) -> WorkspaceTask {
    .init(id: id, project: "", title: id, runIDs: [id], updatedAt: Date(timeIntervalSince1970: updated))
  }

  func testRootSearchThresholdsTrimWhitespaceAndUseClientUTF16Length() {
    XCTAssertFalse(CommandMenuSearch.searchesTasks(" a "))
    XCTAssertTrue(CommandMenuSearch.searchesTasks(" 任务 "))
    XCTAssertFalse(CommandMenuSearch.searchesContent(" 任务 "))
    XCTAssertTrue(CommandMenuSearch.searchesContent("task"))
    XCTAssertTrue(CommandMenuSearch.searchesTasks("🙂"))
    XCTAssertFalse(CommandMenuSearch.searchesContent("🙂"))
  }

  func testMetadataSearchExcludesContentButRetainsBranchMatches() {
    let tasks = [task("message"), task("branch"), task("ab title")]
    var request = TaskSearchRequest(query: "ab", tasks: tasks, names: [:], notes: ["message": "ab message"],
      branches: ["branch": "ab-branch"], runs: [], includeContentResults: false)
    XCTAssertEqual(request.search().map(\.id), ["ab title", "branch"])
    request.includeContentResults = true
    XCTAssertEqual(request.search().map(\.id), ["ab title", "message", "branch"])
  }

  func testRecentsPrioritizeUnreadThenVisitsThenUpdatesAndExcludeHiddenTasks() {
    var library = WorkspaceLibrary()
    library.tasks = [task("current", updated: 100), task("new", updated: 9), task("visited", updated: 1),
      task("unread", updated: 2), task("archived", updated: 300), task("draft", updated: 400)]
    library.tasks[4].archived = true
    library.tasks[5].popoutDraft = true
    library.unreadTasks = ["unread", "archived"]
    library.recentTaskIDs = ["missing", "visited", "visited", "current", "draft"]
    XCTAssertEqual(CommandMenuSearch.recent(library: library, currentID: "current").map(\.id),
      ["unread", "visited", "new"])
    library.tasks += (0..<10).map { task("extra\($0)") }
    XCTAssertEqual(CommandMenuSearch.recent(library: library, currentID: "current").count, 7)
  }

  func testPinnedTasksUseSidebarOrderAndStayOutOfRecents() {
    var library = WorkspaceLibrary()
    library.tasks = [task("a"), task("b"), task("current"), task("archived"), task("recent")]
    for index in 0...3 { library.tasks[index].pinned = true }
    library.tasks[3].archived = true
    library.sidebar.order[SidebarLayout.pinned] = ["t:b", "t:a", "t:current"]
    XCTAssertEqual(CommandMenuSearch.pinned(library: library, currentID: "current").map(\.id),
      ["b", "a"])
    XCTAssertEqual(CommandMenuSearch.recent(library: library, currentID: "current").map(\.id),
      ["recent"])
  }

  @MainActor func testRecentTaskNumberCommandsFollowVisibleRecentList() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [task("current", updated: 10), task("visited", updated: 1),
      task("unread", updated: 2), task("pinned", updated: 20)]
    store.library.tasks[3].pinned = true
    store.library.recentTaskIDs = ["visited", "current"]
    store.library.unreadTasks = ["unread"]
    store.selection = "current"
    XCTAssertEqual(store.recentCommandTasks.map(\.id), ["unread", "visited"])
    XCTAssertEqual(DesktopCommand.recentChatSlot("recent-chat-1"), 0)
    XCTAssertEqual(DesktopCommand.recentChatSlot("recent-chat-6"), 5)
    XCTAssertNil(DesktopCommand.recentChatSlot("recent-chat-7"))
    XCTAssertTrue(store.commandEnabled("recent-chat-1"))
    XCTAssertFalse(store.commandEnabled("recent-chat-3"))
    store.executeCommand("recent-chat-1")
    XCTAssertEqual(store.selectedTask?.id, "unread")
    XCTAssertFalse(store.library.unreadTasks.contains("unread"))
    XCTAssertEqual(store.recentCommandTasks.map(\.id), ["current", "visited"])
    store.openSettings(.general)
    XCTAssertFalse(store.commandEnabled("recent-chat-1"))
    await store.shutdown()
  }

  func testCommandGroupsFollowCurrentCodexMenuCategories() {
    let groups = Dictionary(uniqueKeysWithValues: DesktopCommand.all.map { ($0.id, $0.group) })
    XCTAssertEqual(groups["archive"], .chat)
    XCTAssertEqual(groups["plan"], .chat)
    XCTAssertEqual(groups["clear-prompt"], .chat)
    XCTAssertEqual(groups["add-photos"], .chat)
    XCTAssertEqual(groups["add-files"], .chat)
    XCTAssertEqual(groups["toggle-worktree-mode"], .chat)
    XCTAssertEqual(groups["open-task-window"], .chat)
    XCTAssertEqual(groups["next-task"], .navigation)
    XCTAssertEqual(groups["focus-chat-1"], .navigation)
    XCTAssertEqual(groups["recent-chat-1"], .navigation)
    XCTAssertEqual(groups["browser-new"], .panels)
    XCTAssertEqual(groups["task-summary"], .panels)
    XCTAssertEqual(groups["focus-tab-1"], .panels)
    XCTAssertEqual(groups["branch"], .project)
    XCTAssertEqual(groups["settings"], .configure)
    XCTAssertEqual(groups["open-skills"], .skills)
    XCTAssertEqual(groups["reload-skills"], .skills)
    XCTAssertEqual(groups["pet"], .app)
  }

  @MainActor func testPlanCommandMenuTogglesModeWithoutChangingDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.draft = "Keep this draft"
    XCTAssertTrue(DesktopCommand.search(query: "计划模式").contains { $0.id == "plan" })
    XCTAssertTrue(TaskWindowCommandContext.owns("plan"))

    store.showingCommands = true
    XCTAssertTrue(store.paletteCommandEnabled("plan"))
    store.executePaletteCommand("plan")
    XCTAssertEqual(store.chatMode, .plan)
    XCTAssertEqual(store.draft, "Keep this draft")

    store.showingCommands = true
    store.executePaletteCommand("plan")
    XCTAssertEqual(store.chatMode, .standard)
    XCTAssertEqual(store.draft, "Keep this draft")

    store.openSettings(.general)
    XCTAssertFalse(store.commandEnabled("plan"))
    await store.shutdown()
  }

  @MainActor func testClearPromptKeepsAttachmentsAndOtherWindowDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let task = task("other")
    store.library.tasks = [task]
    store.setTaskWindowDraft("Other window prompt", taskID: task.id)
    store.draft = "Main prompt"
    let image = ImageAttachment(id: UUID(), name: "screen.png", mimeType: "image/png",
      byteCount: 4, sha256: "image")
    let file = FileAttachment(id: UUID(), name: "notes.txt", byteCount: 5,
      sha256: "file", isPDF: false)
    store.library.draftImages[store.draftKey] = [image]
    store.library.draftFiles[store.draftKey] = [file]
    XCTAssertTrue(DesktopCommand.search(query: "清除提示").contains { $0.id == "clear-prompt" })
    XCTAssertTrue(TaskWindowCommandContext.owns("clear-prompt"))

    store.showingCommands = true
    store.executePaletteCommand("clear-prompt")
    XCTAssertEqual(store.draft, "")
    XCTAssertEqual(store.draftImages.map(\.id), [image.id])
    XCTAssertEqual(store.draftFiles.map(\.id), [file.id])
    XCTAssertEqual(store.taskWindowDraft(task.id), "Other window prompt")
    store.openSettings(.general)
    XCTAssertFalse(store.commandEnabled("clear-prompt"))
    await store.shutdown()
  }

  @MainActor func testAttachmentPickerCommandsUseComposerAvailabilityAndWindowOwnership() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    for id in ["add-photos", "add-files"] {
      XCTAssertTrue(DesktopCommand.search(query: DesktopCommand.all.first { $0.id == id }!.title)
        .contains { $0.id == id })
      XCTAssertTrue(TaskWindowCommandContext.owns(id))
      XCTAssertTrue(store.commandEnabled(id))
    }
    store.importingImages = true
    XCTAssertFalse(store.commandEnabled("add-photos"))
    XCTAssertFalse(store.commandEnabled("add-files"))
    store.importingImages = false
    store.importingFiles = true
    XCTAssertFalse(store.commandEnabled("add-photos"))
    XCTAssertFalse(store.commandEnabled("add-files"))
    store.importingFiles = false
    store.openSettings(.general)
    XCTAssertFalse(store.commandEnabled("add-photos"))
    XCTAssertFalse(store.commandEnabled("add-files"))
    await store.shutdown()
  }

  @MainActor func testWorktreeModeCommandTogglesOnlyAnEligibleNewProjectTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertFalse(store.commandEnabled("toggle-worktree-mode"))
    store.library.projects = [root.path]
    store.project = root
    store.workspace.gitAvailable = true
    store.draft = "Keep project draft"
    XCTAssertTrue(store.commandEnabled("toggle-worktree-mode"))
    XCTAssertEqual(store.newTaskExecution, .local)

    store.executeCommand("toggle-worktree-mode")
    XCTAssertEqual(store.newTaskExecution, .worktree)
    XCTAssertEqual(store.draft, "Keep project draft")
    store.executeCommand("toggle-worktree-mode")
    XCTAssertEqual(store.newTaskExecution, .local)
    XCTAssertEqual(store.draft, "Keep project draft")

    store.library.tasks = [.init(id: "existing", project: root.path, title: "Existing", runIDs: [])]
    store.selectTask(store.library.tasks[0])
    XCTAssertFalse(store.commandEnabled("toggle-worktree-mode"))
    store.executeCommand("toggle-worktree-mode")
    XCTAssertEqual(store.newTaskExecution, .local)
    XCTAssertTrue(TaskWindowCommandContext.owns("toggle-worktree-mode"))
    await store.shutdown()
  }

  @MainActor func testOpenTaskWindowCommandUsesSelectedTaskAndWorkspaceRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let task = task("current")
    store.library.tasks = [task]
    store.selectTask(task)
    XCTAssertTrue(store.commandEnabled("open-task-window"))
    store.executeCommand("open-task-window")
    let first = try XCTUnwrap(store.taskWindowOpenRequest)
    XCTAssertEqual(first.taskID, task.id)
    XCTAssertEqual(first.dataRoot, TaskWindowRoute.workspacePath(root))
    store.executeCommand("open-task-window")
    let second = try XCTUnwrap(store.taskWindowOpenRequest)
    XCTAssertNotEqual(first.id, second.id, "Each command opens another window for the same task")
    store.taskWindowOpenRequest = nil
    store.openSettings()
    XCTAssertFalse(store.commandEnabled("open-task-window"))
    store.executeCommand("open-task-window")
    XCTAssertNil(store.taskWindowOpenRequest)
    await store.shutdown()
  }

  @MainActor func testTaskSummaryCommandOnlyTargetsAnOpenTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let initial = store.taskSummaryToggleRequest
    XCTAssertFalse(store.commandEnabled("task-summary"))
    store.executeCommand("task-summary")
    XCTAssertEqual(store.taskSummaryToggleRequest, initial)
    let current = task("summary")
    store.library.tasks = [current]
    store.selectTask(current)
    XCTAssertTrue(store.commandEnabled("task-summary"))
    store.executeCommand("task-summary")
    XCTAssertNotEqual(store.taskSummaryToggleRequest, initial)
    store.openSettings()
    XCTAssertFalse(store.commandEnabled("task-summary"))
    await store.shutdown()
  }

  func testVisitOrderMigratesPersistsAndPrunesDeletedTasks() throws {
    var library = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(library.recentTaskIDs.isEmpty)
    library.tasks = [task("a"), task("b"), task("draft")]
    library.tasks[2].popoutDraft = true
    XCTAssertTrue(library.recordTaskVisit("a"))
    XCTAssertTrue(library.recordTaskVisit("b"))
    XCTAssertTrue(library.recordTaskVisit("a"))
    XCTAssertFalse(library.recordTaskVisit("a"))
    XCTAssertFalse(library.recordTaskVisit("draft"))
    XCTAssertFalse(library.recordTaskVisit("missing"))
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.recentTaskIDs, ["a", "b"])
    library.tasks[0].archived = true
    library.deleteArchivedTasks(["a"])
    XCTAssertEqual(library.recentTaskIDs, ["b"])
  }

  @MainActor func testFirstNavigationRecordsRestoredTaskAndPersistsNewVisitWithoutChangingDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [task("a"), task("b")]
    store.library.drafts = ["a": "Draft A", "b": "Draft B"]
    store.selection = "a"
    store.selectTask(store.library.tasks[1])
    XCTAssertEqual(store.library.recentTaskIDs, ["b", "a"])
    XCTAssertEqual(store.library.drafts, ["a": "Draft A", "b": "Draft B"])
    let saved = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.recentTaskIDs, ["b", "a"])
    await store.shutdown()
  }

}
