import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class ContentTabDragSourceTests: XCTestCase {
  private func event(_ type: NSEvent.EventType, at point: NSPoint, count: Int = 1) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0))
  }

  func testDoubleClickSelectsThenTogglesExactlyOnceAndTripleClickOnlySelects() throws {
    let view = ContentTabDragSource.SourceView(frame:.init(x:0,y:0,width:100,height:30))
    var actions:[String] = []
    view.select = { actions.append("select") }
    view.doubleClick = { actions.append("toggle") }
    for count in 1...3 {
      view.mouseDown(with:try event(.leftMouseDown,at:.init(x:10,y:10),count:count))
      view.mouseUp(with:try event(.leftMouseUp,at:.init(x:10,y:10),count:count))
    }
    XCTAssertEqual(actions,["select","select","toggle","select"])
  }
  func testDisabledOutsideAndDismantledDoubleClicksCannotToggle() throws {
    let view = ContentTabDragSource.SourceView(frame:.init(x:0,y:0,width:100,height:30))
    view.select = { XCTFail("Inactive pointer must not select") }
    view.doubleClick = { XCTFail("Inactive pointer must not toggle") }
    let down = try event(.leftMouseDown,at:.init(x:10,y:10),count:2)
    let up = try event(.leftMouseUp,at:.init(x:10,y:10),count:2)
    view.isEnabled = false; view.mouseDown(with:down); view.mouseUp(with:up)
    view.isEnabled = true; view.mouseDown(with:down)
    view.mouseUp(with:try event(.leftMouseUp,at:.init(x:150,y:10),count:2))
    view.mouseDown(with:down); view.isEnabled = false; view.mouseUp(with:up)
    view.isEnabled = true; view.mouseDown(with:down)
    ContentTabDragSource.dismantleNSView(view,coordinator:())
    view.mouseUp(with:up)
    XCTAssertNil(view.doubleClick)
  }
  func testSelectionRemovingOrDisablingSourceCancelsFollowingDoubleClick() throws {
    for remove in [true,false] {
      let view = ContentTabDragSource.SourceView(frame:.init(x:0,y:0,width:100,height:30))
      var selections = 0
      view.select = {
        selections += 1
        if remove { ContentTabDragSource.dismantleNSView(view,coordinator:()) }
        else { view.isEnabled = false }
      }
      view.doubleClick = { XCTFail("Selection invalidated the pointer source") }
      view.mouseDown(with:try event(.leftMouseDown,at:.init(x:10,y:10),count:2))
      view.mouseUp(with:try event(.leftMouseUp,at:.init(x:10,y:10),count:2))
      XCTAssertEqual(selections,1)
    }
  }

  func testTitleClickSelectsOnceAndReleaseOutsideDoesNotSelect() throws {
    let view = ContentTabDragSource.SourceView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    var selected = 0
    view.select = { selected += 1 }
    let down = try event(.leftMouseDown, at: NSPoint(x: 10, y: 10))
    let up = try event(.leftMouseUp, at: NSPoint(x: 10, y: 10))
    view.mouseDown(with: down)
    view.mouseUp(with: up)
    view.mouseUp(with: up)
    XCTAssertEqual(selected, 1)
    view.mouseDown(with: down)
    view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 150, y: 10)))
    XCTAssertEqual(selected, 1)
    XCTAssertNil(view.pointerDown)
  }

  func testSmallPointerMotionDoesNotStartDragOrLoseClick() throws {
    let view = ContentTabDragSource.SourceView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    view.token = "fixture"
    var started = 0, selected = 0
    view.begin = { started += 1; return nil }
    view.select = { selected += 1 }
    view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
    view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 12, y: 11)))
    XCTAssertEqual(started, 0)
    view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 12, y: 11)))
    XCTAssertEqual(selected, 1)
  }

  func testDismantlingSourceCancelsPendingClickAndDropsLiveCallbacks() throws {
    let view = ContentTabDragSource.SourceView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    var selected = false
    view.select = { selected = true }
    view.begin = { UUID() }
    view.end = { _ in XCTFail("No drag started") }
    view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
    ContentTabDragSource.dismantleNSView(view, coordinator: ())
    view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 10, y: 10)))
    XCTAssertFalse(selected)
    XCTAssertNil(view.begin)
    XCTAssertNil(view.end)
  }

  func testCompletionIsExactlyOnceEvenWhenCallbackReenters() {
    let id = UUID()
    var received: [UUID] = []
    var completion: TabDragCompletion!
    completion = TabDragCompletion(id: id) { received.append($0); completion.finish() }
    completion.finish()
    completion.finish()
    XCTAssertEqual(received, [id])
  }

  func testLateSystemCompletionDoesNotClearANewerModelSession() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-drag-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    defer { store.workspace.browser.shutdown(); try? FileManager.default.removeItem(at: root) }
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.beginWorkspaceTabDrag(tab.id)
    let first = try XCTUnwrap(store.workspaceTabDragSessionID)
    let completion = TabDragCompletion(id: first) { store.endWorkspaceTabDrag(session: $0) }
    store.beginWorkspaceTabDrag(tab.id)
    let second = store.workspaceTabDragSessionID
    completion.finish()
    XCTAssertEqual(store.workspaceTabDragSessionID, second)
    XCTAssertEqual(store.draggingWorkspaceTabID, tab.id)
  }
}
