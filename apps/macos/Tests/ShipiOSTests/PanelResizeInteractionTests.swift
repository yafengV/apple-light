import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class PanelResizeInteractionTests: XCTestCase {
  private func mouse(_ type: NSEvent.EventType, x: Double, y: Double, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: .init(x: x, y: y), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
  }
  private func key(_ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: code)!
  }
  private func handle() -> PanelResizeHandle.ResizeView {
    _ = NSApplication.shared
    let view = PanelResizeHandle.ResizeView(frame: .init(x: 0, y: 0, width: 6, height: 300))
    view.position = 400
    view.limits = 280...700
    return view
  }

  func testPointerDragTracksPhysicalSideAfterPanelSwap() {
    for leading in [true, false] {
      let view = handle()
      view.growsTowardLeading = leading
      var changes: [Double] = [], ended = 0
      view.onResize = { changes.append($0) }
      view.onEnd = { ended += 1 }
      view.mouseDown(with: mouse(.leftMouseDown, x: 500, y: 200))
      view.mouseDragged(with: mouse(.leftMouseDragged, x: 450, y: 200))
      XCTAssertEqual(view.position, leading ? 450 : 350)
      view.mouseDragged(with: mouse(.leftMouseDragged, x: 470, y: 200))
      XCTAssertEqual(view.position, leading ? 430 : 370, "Deltas must use the initial size, not accumulate")
      XCTAssertEqual(ended, 0)
      view.mouseUp(with: mouse(.leftMouseUp, x: 470, y: 200))
      XCTAssertEqual(ended, 1)
      XCTAssertEqual(changes.count, 2)
    }
  }

  func testArrowKeysFollowDividerDirectionButAccessibilityAlwaysChangesSize() {
    for leading in [true, false] {
      let view = handle()
      view.growsTowardLeading = leading
      view.keyDown(with: key(123))
      XCTAssertEqual(view.position, leading ? 420 : 380)
      view.keyDown(with: key(124))
      XCTAssertEqual(view.position, 400)
      XCTAssertTrue(view.accessibilityPerformIncrement())
      XCTAssertEqual(view.position, 420)
      XCTAssertTrue(view.accessibilityPerformDecrement())
      XCTAssertEqual(view.position, 400)
    }
  }

  func testBottomResizeGrowsUpAndClampsPointerAndKeyboardInput() {
    let view = handle()
    view.axis = .horizontal
    view.growsTowardLeading = false
    view.position = 235
    view.limits = 140...400
    view.mouseDown(with: mouse(.leftMouseDown, x: 0, y: 200))
    view.mouseDragged(with: mouse(.leftMouseDragged, x: 0, y: 250))
    XCTAssertEqual(view.position, 285)
    view.mouseDragged(with: mouse(.leftMouseDragged, x: 0, y: 500))
    XCTAssertEqual(view.position, 400)
    view.mouseUp(with: mouse(.leftMouseUp, x: 0, y: 500))
    view.keyDown(with: key(126))
    XCTAssertEqual(view.position, 400)
    view.keyDown(with: key(125))
    XCTAssertEqual(view.position, 380)
    view.setAccessibilityValue(NSNumber(value: -20))
    XCTAssertEqual(view.position, 140)
    view.setAccessibilityValue(NSNumber(value: Double.nan))
    XCTAssertEqual(view.position, 140)
  }

  func testDoubleClickResetsWithoutLeavingDragOriginOrFinishingOldGesture() {
    let view = handle()
    var reset = 0, ended = 0, changed = 0
    view.onReset = { reset += 1 }
    view.onEnd = { ended += 1 }
    view.onResize = { _ in changed += 1 }
    view.mouseDown(with: mouse(.leftMouseDown, x: 500, y: 200, clicks: 2))
    view.mouseDragged(with: mouse(.leftMouseDragged, x: 450, y: 200))
    view.mouseUp(with: mouse(.leftMouseUp, x: 450, y: 200))
    XCTAssertEqual(reset, 1)
    XCTAssertEqual(ended, 0)
    XCTAssertEqual(changed, 0)
  }

  func testIndependentTaskSizesSurviveNavigationWithoutChangingOtherWindowsOrSessions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-resize-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let window = TaskWindowPanelSessions(), otherWindow = TaskWindowPanelSessions()
    defer { window.shutdown(); otherWindow.shutdown() }
    let first = window.panels(for: "first", project: root.path)
    let terminal = try XCTUnwrap(first.newTerminal())
    let pid = terminal.view.process.shellPid
    first.resizeInspector(to: 460)
    first.resizeTerminal(to: 310)
    let second = window.panels(for: "second", project: root.path)
    second.resizeInspector(to: 330)
    let restored = window.panels(for: "first", project: root.path)
    XCTAssertTrue(restored === first)
    XCTAssertEqual(restored.panelSizes, .init(inspectorWidth: 460, terminalHeight: 310))
    XCTAssertTrue(restored.terminal === terminal)
    XCTAssertEqual(restored.terminal?.view.process.shellPid, pid)
    XCTAssertTrue(terminal.view.process.running)
    XCTAssertEqual(second.panelSizes.inspectorWidth, 330)
    XCTAssertEqual(otherWindow.panels(for: "first", project: root.path).panelSizes, .init())
    XCTAssertEqual(store.panelSizes, .init())
    first.resetInspectorSize()
    XCTAssertNil(first.panelSizes.inspectorWidth)
    XCTAssertEqual(first.panelSizes.terminalHeight, 310)
    first.resetTerminalSize()
    XCTAssertEqual(first.panelSizes, .init())
  }

  func testInvalidIndependentDimensionsCannotPoisonLayout() {
    let panels = TaskWindowPanels(taskID: "task")
    panels.resizeInspector(to: .nan)
    panels.resizeTerminal(to: .infinity)
    panels.resizeInspector(to: -1)
    panels.resizeTerminal(to: -1)
    XCTAssertEqual(panels.panelSizes, .init())
    panels.resizeInspector(to: 700)
    XCTAssertEqual(panels.panelSizes.inspector(available: 700), 374)
    XCTAssertEqual(panels.panelSizes.inspector(available: 1_400), 700)
  }
}
