import AppKit
import XCTest
@testable import ShipiOS

final class TaskSearchPresentationTests: XCTestCase {
  private func result(_ id: String, pinned: Bool = false, date: Double = 0) -> TaskSearchResult {
    .init(task: .init(id: id, project: "", title: id, runIDs: [], pinned: pinned,
      updatedAt: Date(timeIntervalSince1970: date)), projectTitle: "无项目", source: nil, snippet: nil)
  }

  func testEmptyQueryShowsPinsInSidebarOrderThenNewestAndLimitsNineTotal() {
    let input = [result("pin-a", pinned: true), result("pin-b", pinned: true)]
      + (0..<12).map { result("task-\($0)", date: Double($0)) }
    let groups = TaskSearchPresentation.groups(input + [input[0]], query: " \n", pinnedOrder: ["pin-b", "pin-a"])
    XCTAssertEqual(groups.map(\.id), ["pinned", "recent"])
    XCTAssertEqual(groups[0].results.map(\.id), ["pin-b", "pin-a"])
    XCTAssertEqual(groups[1].results.map(\.id), (5...11).reversed().map { "task-\($0)" })
    XCTAssertEqual(groups.flatMap(\.results).count, 9)
    let onlyPins = TaskSearchPresentation.groups((0..<12).map { result("p\($0)", pinned: true) }, query: "")
    XCTAssertEqual(onlyPins.map(\.id), ["pinned"])
    XCTAssertEqual(onlyPins[0].results.count, 9)
  }

  func testQueriedResultsPreserveSearchRankingAndDeduplicateBeforeLimit() {
    let input = (0..<12).map { result("task-\($0)", pinned: $0 == 11, date: Double($0)) }
    let groups = TaskSearchPresentation.groups([input[0]] + input, query: "task")
    XCTAssertEqual(groups.map(\.id), ["results"])
    XCTAssertEqual(groups.flatMap(\.results).map(\.id), (0..<9).map { "task-\($0)" })
    XCTAssertTrue(TaskSearchPresentation.groups([], query: "").isEmpty)
    XCTAssertTrue(TaskSearchPresentation.groups([], query: "missing").isEmpty)
    XCTAssertNil(TaskSearchPresentation.shortcutCommand(9))
    XCTAssertNil(TaskSearchPresentation.shortcutCommand(-1))
  }

  @MainActor func testResultKeysFollowNumberTargetCustomBindingsAndIMEGuard() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    XCTAssertEqual(TaskSearchPresentation.shortcutSlot(ShortcutBinding("⌃2"), preferences: preferences), 1)
    XCTAssertNil(TaskSearchPresentation.shortcutSlot(ShortcutBinding("⌘2"), preferences: preferences))
    try preferences.setNumberShortcutTarget(.sidebar)
    XCTAssertEqual(TaskSearchPresentation.shortcutSlot(ShortcutBinding("⌘2"), preferences: preferences), 1)
    XCTAssertNil(TaskSearchPresentation.shortcutSlot(ShortcutBinding("⌃2"), preferences: preferences))
    try preferences.set(ShortcutBinding("⌃⇧9"), for: "focus-chat-2")
    XCTAssertEqual(TaskSearchPresentation.shortcutSlot(ShortcutBinding("⌃⇧9"), preferences: preferences), 1)
    XCTAssertNil(TaskSearchPresentation.shortcutSlot(ShortcutBinding("⌘2"), preferences: preferences))
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift],
      timestamp: 0, windowNumber: 0, context: nil, characters: "9", charactersIgnoringModifiers: "9",
      isARepeat: false, keyCode: 25))
    XCTAssertEqual(SearchDialogKeyboardBridge.key(for: event, markedText: false, shortcuts: preferences), .taskSlot(1))
    XCTAssertNil(SearchDialogKeyboardBridge.key(for: event, markedText: true, shortcuts: preferences))
    XCTAssertNil(SearchDialogKeyboardBridge.key(for: event, markedText: false))
    try preferences.set(nil, for: "focus-chat-2")
    XCTAssertNil(SearchDialogKeyboardBridge.key(for: event, markedText: false, shortcuts: preferences))
  }
}
