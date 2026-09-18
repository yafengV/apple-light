import XCTest
@testable import ShipiOS

@MainActor final class AdditionalShortcutTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func testMultipleBindingsCanBeAddedReplacedRemovedAndReloaded() throws {
    let file = try root().appendingPathComponent("shortcuts.json")
    let shortcuts = ShortcutPreferences(file: file)
    let first = ShortcutBinding("⌘⇧L"), second = ShortcutBinding("⌘⌥⇧L"), third = ShortcutBinding("⌃⇧L")
    try shortcuts.replace(nil, with: first, for: "search")
    try shortcuts.replace(nil, with: second, for: "search")
    XCTAssertTrue(shortcuts.matches("search", second))
    XCTAssertThrowsError(try shortcuts.replace(nil, with: second, for: "search"))
    try shortcuts.replace(first, with: third, for: "search")
    XCTAssertEqual(ShortcutPreferences(file: file).bindings("search"), [third, second])
    try shortcuts.replace(third, with: nil, for: "search")
    XCTAssertEqual(shortcuts.binding("search"), second)
    XCTAssertThrowsError(try shortcuts.replace(first, with: third, for: "search"))
    XCTAssertEqual(shortcuts.bindings("search"), [second])
    try shortcuts.set(nil, for: "search")
    XCTAssertTrue(ShortcutPreferences(file: file).bindings("search").isEmpty)
  }

  func testAllDefaultAliasesParticipateInConflictsAndReset() throws {
    let shortcuts = ShortcutPreferences(file: try root().appendingPathComponent("shortcuts.json"))
    let aliases = ["⌃⇥", "⌘⇧]", "⌘⌥→"].map(ShortcutBinding.init)
    XCTAssertEqual(shortcuts.bindings("next-task"), aliases)
    for alias in aliases { XCTAssertThrowsError(try shortcuts.set(alias, for: "search")) }
    try shortcuts.replace(aliases[1], with: nil, for: "next-task")
    try shortcuts.set(aliases[1], for: "search")
    XCTAssertThrowsError(try shortcuts.reset("next-task"))
    XCTAssertEqual(shortcuts.bindings("next-task"), [aliases[0], aliases[2]])
    try shortcuts.set(nil, for: "search")
    try shortcuts.reset("next-task")
    XCTAssertEqual(shortcuts.bindings("next-task"), aliases)
  }

  func testExistingSecondaryCustomKeyWinsOverNewDefaultAlias() throws {
    let file = try root().appendingPathComponent("shortcuts.json")
    let existing = [ShortcutBinding("⌘⇧L"), ShortcutBinding("⌘⇧]")]
    try JSONEncoder().encode(["search": existing]).write(to: file)
    let shortcuts = ShortcutPreferences(file: file)
    XCTAssertEqual(shortcuts.bindings("search"), existing)
    XCTAssertEqual(shortcuts.bindings("next-task"), [ShortcutBinding("⌃⇥"), ShortcutBinding("⌘⌥→")])
    XCTAssertThrowsError(try shortcuts.reset("next-task"))
    try shortcuts.resetAll()
    XCTAssertTrue(shortcuts.matches("next-task", existing[1]))
  }

  func testAdditionalDispatchDoesNotEscapeRecordingsOrOverlays() throws {
    let store = WorkspaceStore(dataRoot: try root())
    let alias = ShortcutBinding("⌘⌥⇧,")
    try store.shortcuts.replace(nil, with: alias, for: "settings")
    XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌘,")))
    store.shortcutCaptureCount = 1
    XCTAssertFalse(store.handleWorkspaceShortcut(alias))
    store.shortcutCaptureCount = 0
    for overlay in WorkspaceOverlay.allCases {
      store.presentedOverlay = overlay
      XCTAssertFalse(store.handleWorkspaceShortcut(alias))
    }
    store.presentedOverlay = nil
    store.showingModelPicker = true
    XCTAssertFalse(store.handleWorkspaceShortcut(alias))
    store.showingModelPicker = false
    store.restoringLibrary = true
    XCTAssertFalse(store.handleWorkspaceShortcut(alias))
    store.restoringLibrary = false
    XCTAssertTrue(store.handleWorkspaceShortcut(alias))
    XCTAssertEqual(store.destination, .settings)
  }

  func testEveryFileAliasAndCustomizedLineShortcutRouteInFileContext() async throws {
    let store = WorkspaceStore(dataRoot: try root())
    store.workspace = DeveloperWorkspace(fileReader: { _, _ in "one\ntwo" })
    store.workspace.root = URL(fileURLWithPath: "/fixture")
    store.pane = "files"; store.showingInspector = true
    await store.workspace.openFile("first")
    await store.workspace.openFile("second")
    for value in ["⌘⇧[", "⌘⌥←", "⌃⇧⇥", "⌘⇧]", "⌘⌥→", "⌃⇥"] {
      let before = store.workspace.selectedFile
      XCTAssertTrue(store.handleFileShortcut(ShortcutBinding(value)))
      XCTAssertNotEqual(store.workspace.selectedFile, before)
    }
    await store.workspace.openFile("second")
    let custom = ShortcutBinding("⌘⇧L")
    try store.shortcuts.set(custom, for: "browser-address")
    XCTAssertFalse(store.handleFileShortcut(ShortcutBinding("⌘L")))
    XCTAssertTrue(store.handleFileShortcut(custom))
    XCTAssertTrue(store.workspace.showingFileLine)
    store.openSettings()
    XCTAssertFalse(store.handleFileShortcut(custom))
  }

  func testPanelToggleAndExplicitReviewOpenRemainDistinct() throws {
    let store = WorkspaceStore(dataRoot: try root())
    // No filesystem reads are needed for this routing test.
    store.project = URL(fileURLWithPath: "/fixture")
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌘⇧E")))
    XCTAssertTrue(store.filesVisible)
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌘⇧E")))
    XCTAssertFalse(store.showingInspector)
    store.executeCommand("review-open")
    XCTAssertEqual(store.activeWorkspaceTabID, "review:new:/fixture")
    XCTAssertFalse(store.showingInspector)
    store.executeCommand("review-open")
    XCTAssertEqual(store.activeWorkspaceTabID, "review:new:/fixture")
    store.executeCommand("review")
    XCTAssertTrue(store.showingInspector)
    XCTAssertEqual(store.pane, "review")
    store.executeCommand("review")
    XCTAssertFalse(store.showingInspector)
    store.openSettings()
    store.executeCommand("review")
    XCTAssertEqual(store.destination, .settings)
    XCTAssertFalse(store.showingInspector)
  }
}
