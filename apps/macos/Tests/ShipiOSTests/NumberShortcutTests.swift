import XCTest
@testable import ShipiOS

@MainActor final class NumberShortcutTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func testPreferenceSwapsAllSlotsAndResetAllPreservesNumberTarget() throws {
    let file = try root().appendingPathComponent("shortcuts.json")
    let keys = ShortcutPreferences(file: file)
    for number in 1...9 {
      XCTAssertEqual(keys.binding("focus-tab-\(number)"), ShortcutBinding("⌘\(number)"))
      XCTAssertEqual(keys.binding("focus-chat-\(number)"), ShortcutBinding("⌃\(number)"))
    }
    try keys.setNumberShortcutTarget(.sidebar)
    let loaded = ShortcutPreferences(file: file)
    XCTAssertEqual(loaded.primaryNumberShortcutTarget, .sidebar)
    for number in 1...9 {
      XCTAssertEqual(loaded.binding("focus-tab-\(number)"), ShortcutBinding("⌃\(number)"))
      XCTAssertEqual(loaded.binding("focus-chat-\(number)"), ShortcutBinding("⌘\(number)"))
    }
    let all = DesktopCommand.all.flatMap { loaded.bindings($0.id) }
    XCTAssertEqual(Set(all).count, all.count)
    try loaded.set(ShortcutBinding("⌘⇧L"), for: "search")
    try loaded.resetAll()
    XCTAssertEqual(ShortcutPreferences(file: file).primaryNumberShortcutTarget, .sidebar)
    XCTAssertTrue(loaded.overrides.isEmpty)
    XCTAssertFalse(loaded.hasNumberShortcutConflicts)
  }

  func testLegacyBindingsAndUnknownCommandsSurviveMigrationAndSuppressCollidingDefaults() throws {
    let file = try root().appendingPathComponent("shortcuts.json")
    let legacy = ["search": [ShortcutBinding("⌘1")], "future-command": [ShortcutBinding("⌘⇧9")]]
    try JSONEncoder().encode(legacy).write(to: file)
    let keys = ShortcutPreferences(file: file)
    XCTAssertNil(keys.loadError)
    XCTAssertEqual(keys.overrides, legacy)
    XCTAssertNil(keys.binding("focus-tab-1"))
    XCTAssertTrue(keys.hasNumberShortcutConflicts)
    try keys.setNumberShortcutTarget(.sidebar)
    XCTAssertNil(keys.binding("focus-chat-1"))
    XCTAssertEqual(keys.binding("focus-tab-1"), ShortcutBinding("⌃1"))
    XCTAssertEqual(ShortcutPreferences(file: file).overrides, legacy)
    try keys.set(nil, for: "search")
    XCTAssertFalse(keys.hasNumberShortcutConflicts)
    try keys.set(nil, for: "focus-chat-1")
    XCTAssertFalse(keys.hasNumberShortcutConflicts, "Explicitly disabled commands are not conflicts")
    try keys.reset("focus-chat-1")
    XCTAssertEqual(keys.binding("focus-chat-1"), ShortcutBinding("⌘1"))
  }

  func testCustomNumberBindingWinsAfterSwapAndResetUsesCurrentPreference() throws {
    let keys = ShortcutPreferences(file: try root().appendingPathComponent("shortcuts.json"))
    try keys.set(ShortcutBinding("⌘1"), for: "focus-tab-1")
    try keys.setNumberShortcutTarget(.sidebar)
    XCTAssertEqual(keys.binding("focus-tab-1"), ShortcutBinding("⌘1"))
    XCTAssertNil(keys.binding("focus-chat-1"))
    XCTAssertTrue(keys.hasNumberShortcutConflicts)
    try keys.reset("focus-tab-1")
    XCTAssertEqual(keys.binding("focus-tab-1"), ShortcutBinding("⌃1"))
    XCTAssertEqual(keys.binding("focus-chat-1"), ShortcutBinding("⌘1"))
    XCTAssertFalse(keys.hasNumberShortcutConflicts)
  }

  func testFailedPreferenceWriteAndUnknownVersionPreserveLastGoodState() throws {
    let file = try root().appendingPathComponent("shortcuts.json")
    let keys = ShortcutPreferences(file: file)
    try keys.set(ShortcutBinding("⌘⇧L"), for: "search")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try keys.setNumberShortcutTarget(.sidebar))
    XCTAssertEqual(keys.primaryNumberShortcutTarget, .tabs)
    XCTAssertEqual(keys.binding("search"), ShortcutBinding("⌘⇧L"))
    try FileManager.default.removeItem(at: file)
    try keys.setNumberShortcutTarget(.sidebar)
    let unknown = Data(#"{"version":99,"primaryNumberShortcutTarget":"tabs","overrides":{}}"#.utf8)
    try unknown.write(to: file)
    keys.reload()
    XCTAssertNotNil(keys.loadError)
    XCTAssertEqual(keys.primaryNumberShortcutTarget, .sidebar)
    XCTAssertEqual(keys.binding("search"), ShortcutBinding("⌘⇧L"))
    XCTAssertThrowsError(try keys.setNumberShortcutTarget(.tabs))
    XCTAssertEqual(try Data(contentsOf: file), unknown)
  }

  func testVisibleChatOrderFollowsMixedSectionsAndCollapsedProjects() {
    var library = WorkspaceLibrary()
    library.projects = ["/a", "/b"]
    library.tasks = [
      .init(id: "a1", project: "/a", title: "A1", runIDs: []),
      .init(id: "a2", project: "/a", title: "A2", runIDs: []),
      .init(id: "b1", project: "/b", title: "B1", runIDs: []),
      .init(id: "loose", project: "", title: "Loose", runIDs: []),
      .init(id: "archived", project: "", title: "Archived", runIDs: [], archived: true),
    ]
    library.sidebar.groups = [.init(id: "group", name: "Group")]
    library.moveSidebarItem(.project("/b"), to: "group")
    library.moveSidebarItem(.task("a2"), to: SidebarLayout.pinned)
    XCTAssertEqual(library.visibleSidebarTasks.map(\.id), ["a2", "b1", "a1", "loose"])
    library.sidebar.groups[0].collapsed = true
    library.collapsedProjects.insert("/a")
    XCTAssertEqual(library.visibleSidebarTasks.map(\.id), ["a2", "loose"])
    library.moveSidebarItem(.task("a1"), to: SidebarLayout.pinned, before: .task("a2"))
    XCTAssertEqual(library.visibleSidebarTasks.map(\.id), ["a1", "a2", "loose"])
    library.sidebar.groups[0].collapsed = false
    library.collapsedProjects.insert("/b")
    XCTAssertEqual(library.visibleSidebarTasks.map(\.id), ["a1", "a2", "loose"])
  }

  func testRoutingUsesExactNinthChatAndCannotEscapeSettingsRecordingOrModal() throws {
    let store = WorkspaceStore(dataRoot: try root())
    store.library.tasks = (1...11).map {
      .init(id: "task\($0)", project: "", title: "Chat \($0)", runIDs: ["run\($0)"])
    }
    store.selection = "run1"
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌃9")))
    XCTAssertEqual(store.selectedTask?.id, "task9")
    XCTAssertFalse(store.commandEnabled("focus-chat-0"))
    XCTAssertFalse(store.commandEnabled("focus-tab-0"))
    XCTAssertFalse(store.commandEnabled("focus-chat-10"))
    try store.shortcuts.setNumberShortcutTarget(.sidebar)
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌘2")))
    XCTAssertEqual(store.selectedTask?.id, "task2")
    store.shortcutCaptureCount = 1
    XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌘3")))
    store.shortcutCaptureCount = 0
    store.shortcutResetRequested = true
    XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌘3")))
    store.shortcutResetRequested = false
    store.openSettings(.shortcuts)
    XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌘3")))
    XCTAssertEqual(store.selectedTask?.id, "task2")
    store.closeSettings()
    store.library.tasks.removeLast(3)
    XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌘9")), "9 is not a last-chat alias")
    store.busy = true
    XCTAssertFalse(store.commandEnabled("focus-chat-1"))
  }
}
