import XCTest
@testable import ShipiOS

final class LocalCommandTests: XCTestCase {
  @MainActor func testSlashLocalSelectsTheExistingProjectCheckoutForNewChat() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let project = root.appendingPathComponent("Project")
    store.library.projects = [project.path]
    store.project = project
    store.newTaskExecution = .worktree
    store.draft = "/local"

    var selection = ComposerCommandSelection()
    selection.update(draft: "/loc", enabled: store.enabledComposerCommands)
    XCTAssertEqual(selection.matches, [.local])
    XCTAssertTrue(TaskWindowCommandContext.owns("local"))
    XCTAssertEqual(DesktopCommand.all.first(where: { $0.id == "local" })?.group, .chat)
    XCTAssertTrue(store.canSend)
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertEqual(store.newTaskExecution, .local)
    XCTAssertNil(store.selectedTask)
    XCTAssertEqual(store.draft, "")
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
  }

  @MainActor func testLocalCommandIsUnavailableWithoutSelectedProject() {
    let store = WorkspaceStore()
    store.libraryLoaded = true
    XCTAssertFalse(store.commandEnabled("local"))
    store.draft = "/local"
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertEqual(store.draft, "/local")
    XCTAssertNotNil(store.error)
  }
}
