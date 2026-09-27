import XCTest
@testable import ShipiOS

final class WorktreeCommandTests: XCTestCase {
  @MainActor func testSlashWorktreeSelectsTheNewChatExecutionWithoutStartingIt() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let project = root.appendingPathComponent("Project")
    store.library.projects = [project.path]
    store.project = project
    store.connected = true
    store.workspace.gitAvailable = true
    store.draft = "/worktree"

    var selection = ComposerCommandSelection()
    selection.update(draft: "/work", enabled: store.enabledComposerCommands)
    XCTAssertEqual(selection.matches, [.worktree])
    XCTAssertTrue(TaskWindowCommandContext.owns("worktree"))
    XCTAssertTrue(store.canSend)
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertEqual(store.newTaskExecution, .worktree)
    XCTAssertNil(store.selectedTask)
    XCTAssertEqual(store.draft, "")
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
  }

  @MainActor func testWorktreeCommandIsUnavailableWithoutGitOrForUnrelatedTask() {
    let store = WorkspaceStore()
    store.libraryLoaded = true
    store.project = URL(fileURLWithPath: "/tmp/shipios-command-check")
    store.connected = true
    XCTAssertFalse(store.commandEnabled("worktree"))
    store.workspace.gitAvailable = true
    XCTAssertTrue(store.commandEnabled("worktree"))
    store.library.tasks = [.init(id: "unrelated", project: "", title: "Other", runIDs: [])]
    store.selection = "unrelated"
    XCTAssertFalse(store.commandEnabled("worktree"))
  }
}
