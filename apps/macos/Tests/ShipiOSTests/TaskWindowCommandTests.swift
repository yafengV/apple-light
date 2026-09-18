import XCTest
@testable import ShipiOS

final class TaskWindowCommandTests: XCTestCase {
  func testDisabledOrUnsupportedCommandsNeverInvokeTheTaskAction() {
    var invoked: [String] = []
    let context = TaskWindowCommandContext(enabled: ["pin", "settings"], perform: { invoked.append($0) })
    XCTAssertTrue(context.execute("pin"))
    XCTAssertFalse(context.execute("send"))
    XCTAssertFalse(context.execute("settings"), "Application settings are not a local task command")
    XCTAssertEqual(invoked, ["pin"])
  }

  @MainActor func testWindowBindingsFollowCustomizationsAndRemovingAKeyDoesNotKeepHardcodedFind() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    let context = TaskWindowCommandContext(enabled: ["find", "pin", "send"], perform: { _ in })
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘F"), shortcuts: shortcuts), "find")
    try shortcuts.set(ShortcutBinding("⌃⌥F"), for: "find")
    XCTAssertNil(context.command(for: ShortcutBinding("⌘F"), shortcuts: shortcuts))
    XCTAssertEqual(context.command(for: ShortcutBinding("⌃⌥F"), shortcuts: shortcuts), "find")
    try shortcuts.set(nil, for: "send")
    XCTAssertNil(context.command(for: ShortcutBinding("⌘↵"), shortcuts: shortcuts))
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘W"), shortcuts: shortcuts), "tab-close")
    XCTAssertNil(context.command(for: ShortcutBinding("⌘,"), shortcuts: shortcuts))
    XCTAssertNil(context.command(for: ShortcutBinding("↵"), shortcuts: shortcuts), "Approval/plain editing keys have their own route")
  }

  @MainActor func testBackgroundMainPreviewDoesNotDetermineLocalTaskCommandAvailability() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let main = WorkspaceTask(id: "main-task", project: "", title: "Main", runIDs: [])
    let popout = WorkspaceTask(id: "popout-task", project: "", title: "Popout", runIDs: [])
    store.library.tasks = [main, popout]
    store.selectTask(main)
    let image = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "main.png", root: root)
    store.preview(image)
    XCTAssertFalse(store.commandEnabled("pin"))
    let context = TaskWindowCommandContext(enabled: ["pin"], perform: { _ in store.updateTask(popout.id, pin: true) })
    XCTAssertTrue(context.execute("pin"))
    XCTAssertTrue(store.library.tasks.first { $0.id == popout.id }?.pinned == true)
    XCTAssertFalse(store.library.tasks.first { $0.id == main.id }?.pinned == true)
    XCTAssertEqual(store.presentedOverlay, .imagePreview)
    XCTAssertEqual(store.selectedTask?.id, main.id)
    await store.shutdown()
  }

  func testTaskCommandsStayLocalIncludingUnavailablePanelAndNumberNavigation() {
    for id in ["send", "stop", "find", "pin", "archive", "rename", "fork", "tree", "browser-copy", "tab-close", "focus-tab-1", "focus-chat-9"] {
      XCTAssertTrue(TaskWindowCommandContext.owns(id), id)
    }
    for id in ["settings", "shortcuts", "open", "projects", "plugins", "automations", "new"] {
      XCTAssertFalse(TaskWindowCommandContext.owns(id), id)
    }
  }
}
