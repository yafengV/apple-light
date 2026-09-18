import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class AttentionNavigationTests: XCTestCase {
  private func store(withMissingAgent: Bool = false) async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root,
      agentExecutable: withMissingAgent ? root.appendingPathComponent("missing-agent") : nil)
    await store.restore()
    store.library.notifications = .init(timing: .never)
    return store
  }
  private func run(_ id: String, project: String = "", kind: String = "chat", status: String = "succeeded") -> AgentRun {
    AgentRun(id: id, kind: kind, project: project, status: status, createdAt: 1, updatedAt: 2,
      request: .null, result: nil)
  }
  private func install(_ ids: [String], store: WorkspaceStore, project: String = "") {
    store.library.tasks = ids.map { .init(id: $0, project: project, title: $0, runIDs: [$0]) }
    store.runs = ids.map { run($0, project: project) }
    store.library.chatRuns = store.runs
  }

  func testNavigationCyclesUnreadTasksSkipsArchivedAndPreservesDrafts() async throws {
    let store = await store()
    install(["a", "b", "c"], store: store)
    store.library.tasks[1].archived = true
    store.library.unreadTasks = ["a", "b", "c", "stale"]
    store.selection = "a"
    store.draft = "preserved draft"
    store.openSettings(.appearance)
    store.showingSearch = true
    XCTAssertEqual(store.nextAttentionTask?.id, "c")
    let opened = await store.openNextAttentionTask()
    XCTAssertTrue(opened)
    XCTAssertEqual(store.selection, "c")
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertNil(store.presentedOverlay)
    XCTAssertEqual(store.library.drafts["a"], "preserved draft")
    XCTAssertFalse(store.library.unreadTasks.contains("c"))
    XCTAssertEqual(store.nextAttentionTask?.id, "a")
    let wrapped = await store.openNextAttentionTask()
    XCTAssertTrue(wrapped)
    XCTAssertEqual(store.draft, "preserved draft")
    XCTAssertNil(store.nextAttentionTask)
    XCTAssertFalse(store.commandEnabled("next-attention"))
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.unreadTasks, ["b", "stale"])
    await store.shutdown()
  }

  func testOnlyLocalExecutionBlocksCrossProjectAttention() async {
    let store = await store()
    install(["active", "local"], store: store)
    store.runs[0] = run("active", status: "running")
    store.library.tasks.insert(.init(id: "foreign", project: "/other", title: "Other", runIDs: ["foreign"]), at: 1)
    store.library.unreadTasks = ["local", "foreign"]
    store.selection = "active"
    XCTAssertEqual(store.nextAttentionTask?.id, "foreign")
    store.runs[0] = run("active", kind: "build", status: "running")
    XCTAssertEqual(store.nextAttentionTask?.id, "local")
    store.busy = true
    XCTAssertFalse(store.commandEnabled("next-attention"))
    store.busy = false
    let opened = await store.openNextAttentionTask()
    XCTAssertTrue(opened)
    XCTAssertEqual(store.activeRun?.id, "active")
    XCTAssertNil(store.nextAttentionTask)
    XCTAssertTrue(store.library.unreadTasks.contains("foreign"))
    store.runs[0] = run("active", kind: "build")
    XCTAssertEqual(store.nextAttentionTask?.id, "foreign")
    await store.shutdown()
  }

  func testCrossScopeNavigationCanReachProjectlessTask() async {
    let store = await store()
    install(["standalone"], store: store)
    store.library.drafts["standalone"] = "standalone draft"
    store.library.tasks.append(.init(id: "project", project: "/fixture", title: "Project", runIDs: ["project"]))
    store.project = URL(fileURLWithPath: "/fixture")
    store.connected = true
    store.runs = [run("project", project: "/fixture")]
    store.selection = "project"
    store.draft = "project draft"
    store.library.unreadTasks = ["standalone"]
    let opened = await store.openNextAttentionTask()
    XCTAssertTrue(opened)
    XCTAssertNil(store.project)
    XCTAssertEqual(store.selection, "standalone")
    XCTAssertEqual(store.draft, "standalone draft")
    XCTAssertEqual(store.library.drafts["project"], "project draft")
    await store.shutdown()
  }

  func testCompletionMarksUnreadOnlyWhenNotVisibleAndDoesNotReplayAfterClearing() async {
    let store = await store()
    install(["chat", "build", "cancelled", "history"], store: store)
    store.selection = "chat"
    for id in ["chat", "build", "cancelled"] { store.completionTracker.begin(id) }
    store.observeCompletions([run("chat")], appActive: true)
    XCTAssertTrue(store.library.unreadTasks.isEmpty)
    store.observeCompletions([run("build", kind: "build", status: "failed")], appActive: true)
    XCTAssertEqual(store.library.unreadTasks, ["build"])
    store.observeCompletions([run("cancelled", status: "cancelled"), run("history")], appActive: false)
    XCTAssertEqual(store.library.unreadTasks, ["build"])
    store.clearUnreadTasks()
    store.observeCompletions([run("build", kind: "build", status: "failed")], appActive: false)
    XCTAssertTrue(store.library.unreadTasks.isEmpty)
    store.completionTracker.begin("settings")
    store.library.tasks.append(.init(id: "settings", project: "", title: "Settings", runIDs: ["settings"]))
    store.runs.append(run("settings"))
    store.selection = "settings"
    store.openSettings()
    store.observeCompletions([run("settings")], appActive: true)
    XCTAssertEqual(store.library.unreadTasks, ["settings"])
    await store.shutdown()
  }

  func testFailedProjectOpenCanBeRetriedWithoutConsumingUnread() async throws {
    let store = await store(withMissingAgent: true)
    let project = store.dataRoot.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let path = project.resolvingSymlinksInPath().standardizedFileURL.path
    install(["target"], store: store, project: path)
    store.runs = []
    store.library.unreadTasks = ["target"]
    for _ in 0..<2 {
      let opened = await store.openNextAttentionTask()
      XCTAssertFalse(opened)
      XCTAssertFalse(store.connected)
      XCTAssertEqual(store.library.unreadTasks, ["target"])
      XCTAssertEqual(store.nextAttentionTask?.id, "target")
    }
    await store.shutdown()
  }

  func testClearAllUnreadIsAtomicAndDoesNotNavigateOrChangeDrafts() async throws {
    let store = await store()
    install(["one", "two"], store: store)
    store.selection = "one"
    store.draft = "keep me"
    store.library.unreadTasks = ["one", "two"]
    store.openSettings(.shortcuts)
    store.executeCommand("clear-unread")
    XCTAssertTrue(store.library.unreadTasks.isEmpty)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.draft, "keep me")
    XCTAssertFalse(store.commandEnabled("clear-unread"))
    store.setTaskUnread("one", unread: true)
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    store.clearUnreadTasks()
    XCTAssertEqual(store.library.unreadTasks, ["one"])
    XCTAssertNotNil(store.error)
    store.setTaskUnread("one", unread: false)
    XCTAssertEqual(store.library.unreadTasks, ["one"])
    await store.shutdown()
  }

  func testShiftEscapeBindingAndConflictDetection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    let binding = try XCTUnwrap(shortcuts.binding("clear-unread"))
    XCTAssertEqual(binding, ShortcutBinding("⇧⎋"))
    XCTAssertEqual(binding.keyboardShortcut.key, .escape)
    XCTAssertNil(binding.validationMessage)
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
      timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    XCTAssertEqual(ShortcutBinding(event: event), binding)
    XCTAssertNotNil(ShortcutBinding("⎋").validationMessage)
    XCTAssertThrowsError(try shortcuts.set(binding, for: "search"))
    try shortcuts.set(nil, for: "clear-unread")
    try shortcuts.set(binding, for: "search")
    XCTAssertThrowsError(try shortcuts.reset("clear-unread"))
  }

  func testNewDefaultDoesNotOverrideExistingCustomShortcut() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("shortcuts.json")
    try JSONEncoder().encode(["search": [ShortcutBinding("⌘⌥A")]]).write(to: file)
    let preferences = ShortcutPreferences(file: file)
    XCTAssertEqual(preferences.binding("search"), ShortcutBinding("⌘⌥A"))
    XCTAssertNil(preferences.binding("next-attention"))
    XCTAssertThrowsError(try preferences.reset("next-attention"))
    try preferences.set(nil, for: "search")
    XCTAssertEqual(preferences.binding("next-attention"), ShortcutBinding("⌘⌥A"))
  }

  func testModifiedEscapeRespectsCaptureOverlaysAndCustomBinding() async throws {
    let store = await store()
    install(["one"], store: store)
    store.selection = "one"
    store.library.unreadTasks = ["one"]
    store.openSettings()
    let binding = ShortcutBinding("⇧⎋")
    XCTAssertFalse(store.handleModifiedEscape(ShortcutBinding("⎋")))
    store.shortcutCaptureCount = 1
    XCTAssertFalse(store.handleModifiedEscape(binding))
    store.shortcutCaptureCount = 0
    for overlay in WorkspaceOverlay.allCases {
      store.presentedOverlay = overlay
      XCTAssertFalse(store.handleModifiedEscape(binding))
    }
    store.presentedOverlay = nil
    store.showingModelPicker = true
    XCTAssertFalse(store.handleModifiedEscape(binding))
    store.showingModelPicker = false
    store.showingBranchPicker = true
    XCTAssertFalse(store.handleModifiedEscape(binding))
    store.showingBranchPicker = false
    store.restoringLibrary = true
    XCTAssertFalse(store.handleModifiedEscape(binding))
    store.restoringLibrary = false
    XCTAssertEqual(store.library.unreadTasks, ["one"])
    XCTAssertTrue(store.handleModifiedEscape(binding))
    XCTAssertTrue(store.library.unreadTasks.isEmpty)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertTrue(store.handleModifiedEscape(binding), "Disabled clear must not become a settings-back action")
    try store.shortcuts.set(nil, for: "clear-unread")
    XCTAssertFalse(store.handleModifiedEscape(binding))
    try store.shortcuts.set(binding, for: "search")
    XCTAssertTrue(store.handleModifiedEscape(binding))
    XCTAssertEqual(store.presentedOverlay, .taskSearch)
    await store.shutdown()
  }
}
