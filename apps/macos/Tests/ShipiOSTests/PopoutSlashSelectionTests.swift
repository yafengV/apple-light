import XCTest
@testable import ShipiOS

final class PopoutSlashSelectionTests: XCTestCase {
  func testHomeOffersResumeAndThreadAlsoOffersNew() {
    var selection = PopoutSlashSelection()
    selection.update(draft: "/", canNew: false, tasks: [],
      currentTaskID: nil, hasAttachments: false)
    XCTAssertEqual(selection.items, [.resume])
    selection.update(draft: "/", canNew: true, tasks: [],
      currentTaskID: "current", hasAttachments: false)
    XCTAssertEqual(selection.items, [.new, .resume])
    selection.update(draft: "/n", canNew: true, tasks: [],
      currentTaskID: "current", hasAttachments: false)
    XCTAssertEqual(selection.items, [.new])
    selection.update(draft: "/new note", canNew: true, tasks: [],
      currentTaskID: "current", hasAttachments: false)
    XCTAssertFalse(selection.isVisible)
    selection.update(draft: "/", canNew: true, tasks: [],
      currentTaskID: "current", hasAttachments: true)
    XCTAssertFalse(selection.isVisible)
  }

  func testResumeListsTwentyNewestNonTransientOtherTasks() {
    let now = Date(timeIntervalSince1970: 1_000)
    var tasks = (0..<25).map { index in
      WorkspaceTask(id: "task-\(index)", project: "project", title: "Task \(index)",
        runIDs: [], updatedAt: now.addingTimeInterval(Double(index)))
    }
    var archived = WorkspaceTask(id: "archived", project: "", title: "Archived", runIDs: [],
      updatedAt: now.addingTimeInterval(100))
    archived.archived = true
    tasks.append(archived)
    tasks.append(WorkspaceTask(id: "draft", project: "", title: "Draft", runIDs: [],
      popoutDraft: true, updatedAt: now.addingTimeInterval(101)))
    var selection = PopoutSlashSelection()
    selection.update(draft: "/resume", canNew: true, tasks: tasks,
      currentTaskID: "task-24", hasAttachments: false)
    XCTAssertEqual(selection.handle(.accept), .handled)
    XCTAssertEqual(selection.stage, .recent)
    XCTAssertEqual(selection.items.count, 20)
    XCTAssertEqual(selection.items.first, .task("task-23"))
    XCTAssertEqual(selection.items.last, .task("task-4"))
    XCTAssertEqual(selection.handle(.accept), .accept(.task("task-23")))
  }

  func testRecentKeyboardNavigationAndEscapeRestoreCommands() {
    let task = WorkspaceTask(id: "recent", project: "", title: "Recent", runIDs: [])
    var selection = PopoutSlashSelection()
    selection.update(draft: "/", canNew: true, tasks: [task],
      currentTaskID: nil, hasAttachments: false)
    XCTAssertEqual(selection.handle(.next), .handled)
    XCTAssertEqual(selection.selected, .resume)
    XCTAssertEqual(selection.handle(.accept, isComposing: true), .ignored)
    XCTAssertEqual(selection.handle(.accept), .handled)
    XCTAssertEqual(selection.items, [.task("recent")])
    XCTAssertEqual(selection.handle(.dismiss), .handled)
    XCTAssertEqual(selection.items, [.new, .resume])
    XCTAssertEqual(selection.selected, .resume)
    XCTAssertEqual(selection.handle(.dismiss), .handled)
    XCTAssertFalse(selection.isVisible)
    selection.update(draft: "/r", canNew: true, tasks: [task],
      currentTaskID: nil, hasAttachments: false)
    XCTAssertEqual(selection.items, [.resume])
    XCTAssertTrue(selection.isVisible)
  }

  func testEmptyResumeSubmenuConsumesEnterWithoutSending() {
    var selection = PopoutSlashSelection()
    selection.update(draft: "/resume", canNew: false, tasks: [],
      currentTaskID: nil, hasAttachments: false)
    XCTAssertEqual(selection.handle(.accept), .handled)
    XCTAssertEqual(selection.items, [.empty])
    XCTAssertEqual(selection.handle(.accept), .handled)
  }
}
