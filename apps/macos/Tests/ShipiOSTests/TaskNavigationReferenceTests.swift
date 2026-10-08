import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class TaskNavigationReferenceTests: XCTestCase {
  private struct Reference: Decodable {
    struct Command: Decodable { let id: String; let shipiosID: String; let defaults: [String] }
    struct Recent: Decodable {
      let current: String?; let direction: String; let recent: [String]
      let session: RecentTaskSelection?; let unavailable: [String]; let result: RecentTaskSelection
    }
    struct Adjacent: Decodable { let current: String?; let direction: String; let targets: [String]; let selected: [String] }
    struct Release: Decodable {
      struct Event: Decodable { let ctrlKey: Bool?; let metaKey: Bool?; let altKey: Bool?; let shiftKey: Bool?; let key: String }
      let event: Event; let keys: [String]
    }
    struct Content: Decodable { let mode: String; let current: String; let direction: String; let handled: Bool; let selected: [String] }
    let contentTabCases: [Content]
    let commands: [Command]; let compatiblePairs: [[String]]; let recentCases: [Recent]
    let adjacentCases: [Adjacent]; let releases: [Release]; let cappedVisit: [String]
  }
  private func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "task_navigation_reference_691",
      withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  }
  private func preferences(defaults: [String: [ShortcutBinding]] = [:]) -> ShortcutPreferences {
    ShortcutPreferences(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      commandDefaults: defaults)
  }
  private func event(_ type: NSEvent.EventType = .keyDown, flags: NSEvent.ModifierFlags = .control,
    code: UInt16 = 48, window: Int = 0, repeated: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window,
      context: nil, characters: code == 48 ? "\t" : "x", charactersIgnoringModifiers: code == 48 ? "\t" : "x",
      isARepeat: repeated, keyCode: code)!
  }
  private func context(_ select: @escaping (String) -> Void) -> RecentTaskShortcutContext {
    .init(currentID: "a", recentIDs: ["a", "c", "b"], isAvailable: { _ in true }, title: { $0 }, select: select)
  }

  func testSixCurrentReferenceCommandsRemainDistinctAndKeepTheirOwnDefaults() throws {
    let reference = try reference()
    XCTAssertEqual(reference.commands.count, 6)
    for item in reference.commands {
      let command = DesktopCommand.all.first { $0.id == item.shipiosID }
      XCTAssertNotNil(command, item.id)
      let expected = item.defaults.map { value in
        ShortcutBinding(value.replacingOccurrences(of: "CmdOrCtrl+", with: "⌘")
          .replacingOccurrences(of: "Command+", with: "⌘").replacingOccurrences(of: "Ctrl+", with: "⌃")
          .replacingOccurrences(of: "Shift+", with: "⇧").replacingOccurrences(of: "Alt+", with: "⌥")
          .replacingOccurrences(of: "Tab", with: "⇥").replacingOccurrences(of: "Left", with: "←")
          .replacingOccurrences(of: "Right", with: "→"))
      }
      XCTAssertEqual(command?.defaultBindings, expected, item.id)
    }
  }
  func testActualReferenceRecentSelectionTracesAndVisitLimit() throws {
    let reference = try reference()
    XCTAssertEqual(reference.recentCases.count, 11)
    for sample in reference.recentCases {
      XCTAssertEqual(RecentTaskSelection.step(current: sample.current, direction: sample.direction == "next" ? 1 : -1,
        recent: sample.recent, session: sample.session, isAvailable: { !sample.unavailable.contains($0) }), sample.result)
    }
    XCTAssertEqual(RecentTaskSelection.recordingVisit("current", in: (0..<25).map(String.init)), reference.cappedVisit)
  }
  func testActualReferenceAdjacentChatBoundariesNeverWrap() throws {
    let samples = try reference().adjacentCases
    XCTAssertEqual(samples.count, 10)
    for sample in samples {
      XCTAssertEqual(TaskNavigationOrder.adjacent(current: sample.current,
        direction: sample.direction == "next" ? 1 : -1, targets: sample.targets), sample.selected.first)
    }
  }
  func testOnlyFourReferenceNavigationPairsCanShareBindings() throws {
    let reference = try reference()
    for first in reference.commands.map(\.shipiosID) {
      for second in reference.commands.map(\.shipiosID) where first != second {
        XCTAssertEqual(DesktopCommand.allowsSharedBinding(first, second),
          reference.compatiblePairs.contains { Set($0) == [first, second] }, "\(first)/\(second)")
      }
    }
  }
  func testHeldRecentSelectionFreezesOrderAndCommitsOnlyOnControlRelease() {
    let shortcuts = preferences(), controller = RecentTaskShortcutController()
    var selected: [String] = [], announced: [String] = []
    controller.announce = { announced.append($0) }
    var context = context { selected.append($0) }
    XCTAssertTrue(controller.handle(event(), context: context, shortcuts: shortcuts))
    XCTAssertEqual(controller.session?.selectedID, "c"); XCTAssertTrue(selected.isEmpty)
    context.recentIDs = ["b", "a", "c"]
    XCTAssertTrue(controller.handle(event(repeated: true), context: context, shortcuts: shortcuts))
    XCTAssertEqual(controller.session?.selectedID, "b"); XCTAssertTrue(selected.isEmpty)
    XCTAssertTrue(controller.handle(event(flags: [.control, .shift]), context: context, shortcuts: shortcuts))
    XCTAssertEqual(controller.session?.selectedID, "c")
    XCTAssertFalse(controller.handle(event(.flagsChanged, flags: .control), context: context, shortcuts: shortcuts))
    XCTAssertTrue(selected.isEmpty)
    XCTAssertFalse(controller.handle(event(.keyUp), context: context, shortcuts: shortcuts)); XCTAssertTrue(selected.isEmpty)
    XCTAssertFalse(controller.handle(event(.flagsChanged, flags: []), context: context, shortcuts: shortcuts))
    XCTAssertEqual(selected, ["c"]); XCTAssertNil(controller.session)
    _ = controller.handle(event(.flagsChanged, flags: []), context: context, shortcuts: shortcuts)
    XCTAssertEqual(selected, ["c"]); XCTAssertEqual(announced.count, 3)
  }
  func testActualReferenceReleaseKeysIgnoreShiftAndAnyTriggerModifierCanCommit() throws {
    for sample in try reference().releases {
      let key = sample.event.key == "Tab" ? "⇥" : "x", code: UInt16 = key == "⇥" ? 48 : 7
      var flags: NSEvent.ModifierFlags = []
      if sample.event.ctrlKey == true { flags.insert(.control) }
      if sample.event.metaKey == true { flags.insert(.command) }
      if sample.event.altKey == true { flags.insert(.option) }
      if sample.event.shiftKey == true { flags.insert(.shift) }
      let binding = ShortcutBinding((flags.contains(.control) ? "⌃" : "") + (flags.contains(.command) ? "⌘" : "")
        + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + key)
      for release in sample.keys {
        let shortcuts = preferences(defaults: ["next-recent-task": [binding], "next-tab": [], "previous-tab": []])
        let controller = RecentTaskShortcutController(); controller.announce = { _ in }
        var selected: [String] = []; let context = context { selected.append($0) }
        XCTAssertTrue(controller.handle(event(flags: flags, code: code), context: context, shortcuts: shortcuts))
        if release == "Tab" {
          _ = controller.handle(event(.flagsChanged, flags: [], code: code), context: context, shortcuts: shortcuts)
          XCTAssertTrue(selected.isEmpty)
          _ = controller.handle(event(.keyUp, flags: [], code: code), context: context, shortcuts: shortcuts)
        } else {
          let modifier: NSEvent.ModifierFlags = release == "Control" ? .control : release == "Meta" ? .command : .option
          _ = controller.handle(event(.flagsChanged, flags: flags.subtracting(modifier), code: code), context: context, shortcuts: shortcuts)
        }
        XCTAssertEqual(selected, ["c"], release)
      }
    }
  }
  func testContentPanelPreemptsSharedBindingAndCancelsPendingRecentSelection() {
    let shortcuts = preferences(), controller = RecentTaskShortcutController(); controller.announce = { _ in }
    var selected: [String] = [], tabs: [Int] = []
    var context = context { selected.append($0) }
    _ = controller.handle(event(), context: context, shortcuts: shortcuts)
    context.claimsTabs = { true }; context.selectTab = { tabs.append($0); return true }
    XCTAssertTrue(controller.handle(event(flags: [.control, .shift]), context: context, shortcuts: shortcuts))
    XCTAssertEqual(tabs, [-1]); XCTAssertNil(controller.session)
    _ = controller.handle(event(.flagsChanged, flags: []), context: context, shortcuts: shortcuts)
    XCTAssertTrue(selected.isEmpty)
  }
  func testIndependentCustomTabKeyDoesNotPreemptRecentBinding() throws {
    let shortcuts = preferences(); try shortcuts.set(ShortcutBinding("⌃⌥⇥"), for: "next-tab")
    let controller = RecentTaskShortcutController(); controller.announce = { _ in }
    var selected: [String] = [], tabs: [Int] = []; var context = context { selected.append($0) }
    context.claimsTabs = { true }; context.selectTab = { tabs.append($0); return true }
    _ = controller.handle(event(), context: context, shortcuts: shortcuts)
    XCTAssertEqual(controller.session?.selectedID, "c"); XCTAssertTrue(tabs.isEmpty)
    _ = controller.handle(event(.flagsChanged, flags: []), context: context, shortcuts: shortcuts)
    XCTAssertEqual(selected, ["c"])
  }
  func testBlockedContextChangedRouteAndRemovedTargetNeverCommitStaleSelection() {
    let shortcuts = preferences(), controller = RecentTaskShortcutController(); controller.announce = { _ in }
    var selected: [String] = []; let initial = context { selected.append($0) }
    _ = controller.handle(event(), context: initial, shortcuts: shortcuts)
    _ = controller.handle(event(.flagsChanged, flags: []), context: nil, shortcuts: shortcuts)
    XCTAssertNil(controller.session); XCTAssertTrue(selected.isEmpty)
    _ = controller.handle(event(), context: initial, shortcuts: shortcuts)
    var changed = initial; changed.currentID = "b"
    _ = controller.handle(event(.flagsChanged, flags: []), context: changed, shortcuts: shortcuts)
    XCTAssertNil(controller.session); XCTAssertTrue(selected.isEmpty)
    _ = controller.handle(event(), context: initial, shortcuts: shortcuts)
    var removed = initial; removed.isAvailable = { $0 != "c" }
    _ = controller.handle(event(.flagsChanged, flags: []), context: removed, shortcuts: shortcuts)
    XCTAssertNil(controller.session); XCTAssertTrue(selected.isEmpty)
  }
  func testBothNativeWindowBridgesCancelOnWindowBlurAndTeardown() {
    let shortcuts = preferences(), context = context { _ in XCTFail("Blur must cancel without opening a task") }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSView(); window.contentView = view
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let main = WorkspaceKeyboardBridge.Coordinator(), task = TaskWindowCommandKeyboardBridge.Coordinator()
    main.install(view, store: store); task.install(view)
    defer { main.stop(); task.stop(); window.close() }
    for controller in [main.recent, task.recent] {
      controller.announce = { _ in }
      _ = controller.handle(event(), context: context, shortcuts: shortcuts)
    }
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    XCTAssertNil(main.recent.session); XCTAssertNil(task.recent.session)
    for controller in [main.recent, task.recent] { _ = controller.handle(event(), context: context, shortcuts: shortcuts) }
    main.stop(); task.stop()
    XCTAssertNil(main.recent.session); XCTAssertNil(task.recent.session)
  }
  func testLegacyCustomNavigationMigratesBothContextsAndKeepsUnbindings() throws {
    for version in [1, 2] {
      let shortcuts = preferences()
      var old = ShortcutPreferencesSnapshot(primaryNumberShortcutTarget: .tabs,
        overrides: ["next-task": [ShortcutBinding("⌃⌥⇥")], "previous-task": []], externalBrowserLinkShortcut: .unassigned)
      old.version = version; try shortcuts.restore(old)
      XCTAssertEqual(shortcuts.bindings("next-task"), [ShortcutBinding("⌃⌥⇥")])
      XCTAssertEqual(shortcuts.bindings("next-tab"), [ShortcutBinding("⌃⌥⇥")])
      XCTAssertTrue(shortcuts.bindings("next-recent-task").isEmpty)
      XCTAssertTrue(shortcuts.bindings("previous-task").isEmpty); XCTAssertTrue(shortcuts.bindings("previous-tab").isEmpty)
      XCTAssertTrue(shortcuts.bindings("previous-recent-task").isEmpty); XCTAssertEqual(shortcuts.snapshot.version, 3)
    }
  }
  func testSharedAssignmentsKeepCompatibleDefaultsAndRejectDifferentDirections() throws {
    let shortcuts = preferences()
    try shortcuts.set(ShortcutBinding("⌃⌥⇥"), for: "next-task")
    try shortcuts.set(ShortcutBinding("⌃⌥⇥"), for: "next-tab")
    XCTAssertThrowsError(try shortcuts.set(ShortcutBinding("⌃⌥⇥"), for: "next-recent-task"))
    XCTAssertThrowsError(try shortcuts.set(ShortcutBinding("⌃⌥⇥"), for: "previous-tab"))
    try shortcuts.set(nil, for: "next-task")
    try shortcuts.set(ShortcutBinding("⌃⌥⇥"), for: "next-recent-task")
    XCTAssertEqual(shortcuts.bindings("next-tab"), [ShortcutBinding("⌃⌥⇥")])
  }
  func testVisiblePanelWithNoAdjacentTabFallsBackToHeldRecentSelection() {
    let shortcuts = preferences(), controller = RecentTaskShortcutController(); controller.announce = { _ in }
    var selected: [String] = []; var context = context { selected.append($0) }
    context.claimsTabs = { true }; context.selectTab = { _ in false }
    XCTAssertTrue(controller.handle(event(), context: context, shortcuts: shortcuts))
    XCTAssertEqual(controller.session?.selectedID, "c"); XCTAssertTrue(selected.isEmpty)
    _ = controller.handle(event(.flagsChanged, flags: []), context: context, shortcuts: shortcuts)
    XCTAssertEqual(selected, ["c"])
  }
  func testMainWindowActualSelectionAndDraftRemainUntouchedUntilRelease() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a", "b", "c"].map { .init(id: $0, project: "", title: $0, runIDs: []) }
    store.applyTaskSelection(store.library.tasks[0]); store.library.recentTaskIDs = ["a", "c", "b"]
    store.library.drafts["a"] = "keep draft"
    let original = store.library.recentTaskIDs, controller = RecentTaskShortcutController(); controller.announce = { _ in }
    XCTAssertTrue(controller.handle(event(), context: try XCTUnwrap(store.taskNavigationShortcutContext), shortcuts: store.shortcuts))
    XCTAssertEqual(store.selectedTask?.id, "a"); XCTAssertEqual(store.library.recentTaskIDs, original)
    XCTAssertEqual(store.library.drafts["a"], "keep draft")
    _ = controller.handle(event(.flagsChanged, flags: []), context: store.taskNavigationShortcutContext, shortcuts: store.shortcuts)
    XCTAssertEqual(store.selectedTask?.id, "c"); XCTAssertEqual(store.library.recentTaskIDs, ["c", "a", "b"])
    XCTAssertEqual(store.library.drafts["a"], "keep draft")
    store.presentedOverlay = .commands
    XCTAssertNil(store.taskNavigationShortcutContext)
  }
  func testTaskWindowReleaseNavigatesItsOwnRouteAndMainSelectionIsUnchanged() {
    let shortcuts = preferences(), controller = RecentTaskShortcutController(); controller.announce = { _ in }
    var taskRoute = "a"; let mainRoute = "other"
    let context = context { taskRoute = $0 }
    let commands = TaskWindowCommandContext(enabled: ["next-task", "next-tab"], perform: { _ in }, recentNavigation: context)
    XCTAssertEqual(commands.command(for: ShortcutBinding("⌘⇧]"), shortcuts: shortcuts), "next-task")
    XCTAssertNil(commands.command(for: ShortcutBinding("⌃⇥"), shortcuts: shortcuts), "The release controller owns held navigation")
    _ = controller.handle(event(), context: commands.recentNavigation, shortcuts: shortcuts)
    XCTAssertEqual(taskRoute, "a")
    _ = controller.handle(event(.flagsChanged, flags: []), context: commands.recentNavigation, shortcuts: shortcuts)
    XCTAssertEqual(taskRoute, "c"); XCTAssertEqual(mainRoute, "other")
  }
  func testPersistedVisitHistoryMatchesReferenceTwentyEntryLimit() {
    var library = WorkspaceLibrary()
    library.tasks = (0..<25).map { .init(id: String($0), project: "", title: String($0), runIDs: []) }
    for task in library.tasks { library.recordTaskVisit(task.id) }
    XCTAssertEqual(library.recentTaskIDs, (5..<25).reversed().map(String.init))
  }
  func testSplitContentRoutingCyclesFocusedPaneWithoutOpeningDetachedOrOtherPaneTabs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [.init(id: "a", project: "", title: "a", runIDs: [])]
    store.applyTaskSelection(store.library.tasks[0])
    let first = WorkspaceContentTab.file("first", owner: "a"), second = WorkspaceContentTab.file("second", owner: "a")
    let left = WorkspaceContentTab.file("left", owner: "a"), detached = WorkspaceContentTab.file("detached", owner: "a")
    store.workspaceTabs = [left, first, second, detached]
    store.workspaceTabPlacements[first.id] = .right; store.workspaceTabPlacements[second.id] = .right
    store.workspaceTabPlacements[detached.id] = .detached
    store.activeRightWorkspaceTabID = first.id; store.focusedWorkspaceTabID = first.id; store.showingInspector = true
    XCTAssertTrue(store.adjacentContentTab(1)); XCTAssertEqual(store.activeRightWorkspaceTabID, second.id)
    XCTAssertNil(store.activeWorkspaceTabID)
    XCTAssertTrue(store.adjacentContentTab(1)); XCTAssertEqual(store.activeRightWorkspaceTabID, first.id)
  }

  private final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
  func testInstalledTaskWindowMonitorHandlesKeyDownAndModifierReleaseInHiddenWindow() {
    _ = NSApplication.shared
    let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSView(); window.contentView = view
    let shortcuts = preferences(), coordinator = TaskWindowCommandKeyboardBridge.Coordinator()
    var selected: [String] = []
    coordinator.navigationContext = context { selected.append($0) }; coordinator.shortcuts = shortcuts
    coordinator.recent.announce = { _ in }; coordinator.install(view)
    defer { coordinator.stop(); window.contentView = nil; window.close() }
    NSApplication.shared.sendEvent(event(window: window.windowNumber))
    XCTAssertEqual(coordinator.recent.session?.selectedID, "c"); XCTAssertTrue(selected.isEmpty)
    NSApplication.shared.sendEvent(event(.flagsChanged, flags: [], window: window.windowNumber))
    XCTAssertEqual(selected, ["c"]); XCTAssertNil(coordinator.recent.session)
    XCTAssertFalse(window.isVisible)
  }
  func testInstalledMainWindowMonitorUsesActualTaskContextWithoutEarlySelection() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a", "b", "c"].map { .init(id: $0, project: "", title: $0, runIDs: []) }
    store.applyTaskSelection(store.library.tasks[0]); store.library.recentTaskIDs = ["a", "c", "b"]
    let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; let view = NSView(); window.contentView = view
    let coordinator = WorkspaceKeyboardBridge.Coordinator(); coordinator.recent.announce = { _ in }
    coordinator.install(view, store: store)
    defer { coordinator.stop(); window.contentView = nil; window.close() }
    NSApplication.shared.sendEvent(event(window: window.windowNumber))
    XCTAssertEqual(coordinator.recent.session?.selectedID, "c"); XCTAssertEqual(store.selectedTask?.id, "a")
    NSApplication.shared.sendEvent(event(.flagsChanged, flags: [], window: window.windowNumber))
    XCTAssertNil(coordinator.recent.session); XCTAssertEqual(store.selectedTask?.id, "c")
    XCTAssertFalse(window.isVisible)
  }

  func testAdjacentChatRejectsKeyRepeatWhileRecentNavigationKeepsRepeating() throws {
    let shortcuts = preferences()
    try shortcuts.set(ShortcutBinding("⌃⌥⇥"), for: "next-task")
    XCTAssertTrue(RecentTaskShortcutController.isRepeatedAdjacentChat(event(flags: [.control, .option], repeated: true), shortcuts: shortcuts))
    XCTAssertFalse(RecentTaskShortcutController.isRepeatedAdjacentChat(event(flags: [.control, .option]), shortcuts: shortcuts))
    XCTAssertFalse(RecentTaskShortcutController.isRepeatedAdjacentChat(event(repeated: true), shortcuts: shortcuts))
    let controller = RecentTaskShortcutController(); controller.announce = { _ in }
    let context = context { _ in XCTFail("Repeat must not commit before release") }
    _ = controller.handle(event(), context: context, shortcuts: shortcuts)
    _ = controller.handle(event(repeated: true), context: context, shortcuts: shortcuts)
    XCTAssertEqual(controller.session?.selectedID, "b")
  }

  func testFullContentFollowsActualReferenceUnifiedSelectionTraces() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let traces = try reference().contentTabCases; XCTAssertEqual(traces.count, 10)
    // The reference primary-split atom is distinct from our ordinary side pane.
    // Keep those traces without pretending that the model states are equivalent.
    let cases = traces.filter { $0.mode == "full" }; XCTAssertEqual(cases.count, 6)
    for sample in cases {
      let store = WorkspaceStore(dataRoot: root.appendingPathComponent(UUID().uuidString))
      store.library.tasks = [.init(id: "a", project: "", title: "a", runIDs: [])]
      store.applyTaskSelection(store.library.tasks[0])
      let tabs = ["left", "right1", "right2"].map { WorkspaceContentTab.file($0, owner: "a") }
      store.workspaceTabs = tabs
      for tab in tabs.dropFirst() { store.workspaceTabPlacements[tab.id] = .right }
      store.activeWorkspaceTabID = sample.mode == "full" ? tabs[0].id : nil
      let current = try XCTUnwrap(tabs.first { $0.id == WorkspaceContentTab.file(sample.current, owner: "a").id })
      store.focusedWorkspaceTabID = current.id; store.activeRightWorkspaceTabID = current.id
      store.showingInspector = true
      XCTAssertEqual(store.adjacentContentTab(sample.direction == "next" ? 1 : -1), sample.handled)
      let expected = sample.selected.first == "chat" ? nil : sample.selected.first.map { WorkspaceContentTab.file($0, owner: "a").id }
      XCTAssertEqual(store.focusedWorkspaceTabID, expected, "main \(sample.mode)/\(sample.current)/\(sample.direction)")
    }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("window"))
    store.library.tasks = [.init(id: "a", project: root.path, title: "a", runIDs: [])]
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    for name in ["left", "right1", "right2"] {
      try Data().write(to: root.appendingPathComponent(name))
      XCTAssertTrue(tabs.openFile(name, in: name == "left" ? .left : .right))
    }
    for sample in cases {
      tabs.activate(sample.mode == "full" ? WorkspaceContentTab.file("left", owner: "a").id : nil)
      tabs.activate(WorkspaceContentTab.file(sample.current, owner: "a").id)
      XCTAssertEqual(tabs.navigateAdjacentContentTab(sample.direction == "next" ? 1 : -1), sample.handled)
      let expected = sample.selected.first == "chat" ? nil : sample.selected.first.map { WorkspaceContentTab.file($0, owner: "a").id }
      XCTAssertEqual(tabs.focusedID, expected, "window \(sample.mode)/\(sample.current)/\(sample.direction)")
    }
  }

  func testTaskWindowFailedTabClaimFallsBackToAdjacentChatCommand() {
    let shortcuts = preferences(), controller = RecentTaskShortcutController(); controller.announce = { _ in }
    var navigation = context { _ in XCTFail("This binding is adjacent chat, not recent navigation") }
    navigation.claimsTabs = { true }; navigation.selectTab = { _ in false }
    var performed: [String] = []
    let commands = TaskWindowCommandContext(enabled: ["next-task", "next-tab"], perform: { performed.append($0) }, recentNavigation: navigation)
    XCTAssertFalse(controller.handle(event(flags: [.command, .option], code: 124), context: navigation, shortcuts: shortcuts))
    let id = commands.command(for: ShortcutBinding("⌘⌥→"), shortcuts: shortcuts)
    XCTAssertEqual(id, "next-task")
    if let id { XCTAssertTrue(commands.execute(id)) }
    XCTAssertEqual(performed, ["next-task"])
  }

  func testLegacyBrowserNavigationKeepsItsTaskOwnership() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); defer { store.workspace.browser.shutdown() }
    store.library.tasks = ["a", "b"].map { .init(id: $0, project: "", title: $0, runIDs: []) }
    store.applyTaskSelection(store.library.tasks[0]); store.newBrowserTab()
    let first = try XCTUnwrap(store.workspace.browser.selection)
    store.newBrowserTab(); let second = try XCTUnwrap(store.workspace.browser.selection)
    store.applyTaskSelection(store.library.tasks[1]); store.newBrowserTab()
    let other = try XCTUnwrap(store.workspace.browser.selection)
    store.applyTaskSelection(store.library.tasks[0]); store.workspace.browser.select(first)
    XCTAssertTrue(store.moveLegacyBrowserTab(1)); XCTAssertEqual(store.workspace.browser.selection, second)
    XCTAssertTrue(store.moveLegacyBrowserTab(1)); XCTAssertEqual(store.workspace.browser.selection, first)
    XCTAssertNotEqual(store.workspace.browser.selection, other)
  }

}
