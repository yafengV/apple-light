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
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘["), shortcuts: shortcuts), "back")
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘]"), shortcuts: shortcuts), "forward")
    try shortcuts.set(ShortcutBinding("⌃⌥B"), for: "back")
    XCTAssertNil(context.command(for: ShortcutBinding("⌘["), shortcuts: shortcuts))
    XCTAssertEqual(context.command(for: ShortcutBinding("⌃⌥B"), shortcuts: shortcuts), "back")
    try shortcuts.set(nil, for: "forward")
    XCTAssertNil(context.command(for: ShortcutBinding("⌘]"), shortcuts: shortcuts))
  }

  @MainActor func testPaletteAndTaskSearchBindingsBelongToFocusedWindow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    var invoked: [String] = []
    let context = TaskWindowCommandContext(enabled: ["palette", "palette-alternate", "search"],
      perform: { invoked.append($0) })
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘K"), shortcuts: shortcuts), "palette")
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘⇧P"), shortcuts: shortcuts), "palette-alternate")
    try shortcuts.set(ShortcutBinding("⌃⌥K"), for: "palette")
    XCTAssertNil(context.command(for: ShortcutBinding("⌘K"), shortcuts: shortcuts))
    XCTAssertEqual(context.command(for: ShortcutBinding("⌃⌥K"), shortcuts: shortcuts), "palette")
    try shortcuts.set(ShortcutBinding("⌃⌥S"), for: "search")
    XCTAssertEqual(context.command(for: ShortcutBinding("⌃⌥S"), shortcuts: shortcuts), "search")
    XCTAssertTrue(context.execute("palette"))
    XCTAssertTrue(context.execute("search"))
    XCTAssertEqual(invoked, ["palette", "search"])
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

  @MainActor func testBrowserEditingKeysUseLiveFocusButMenuActionsStayAvailable() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    var browserFocused = false
    var invoked: [String] = []
    let context = TaskWindowCommandContext(enabled: ["browser-back"], perform: { invoked.append($0) },
      keyboardAllowed: { _ in browserFocused })
    XCTAssertNil(context.command(for: ShortcutBinding("⌘←"), shortcuts: shortcuts))
    XCTAssertTrue(context.execute("browser-back"), "Explicit menu selection is independent of editor key handling")
    browserFocused = true
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘←"), shortcuts: shortcuts), "browser-back")
    browserFocused = false
    XCTAssertNil(context.command(for: ShortcutBinding("⌘←"), shortcuts: shortcuts))
    XCTAssertEqual(invoked, ["browser-back"])
  }

  func testTaskCommandsStayLocalIncludingUnavailablePanelAndNumberNavigation() {
    for id in ["palette", "palette-alternate", "search", "send", "stop", "find", "pin", "archive", "rename", "fork", "open-task-window", "tree", "browser-copy", "tab-close", "focus-tab-1", "focus-chat-9"] {
      XCTAssertTrue(TaskWindowCommandContext.owns(id), id)
    }
    for id in ["settings", "shortcuts", "open", "projects", "plugins", "automations", "new"] {
      XCTAssertFalse(TaskWindowCommandContext.owns(id), id)
    }
  }
}
