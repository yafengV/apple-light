import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class ContentTabDropSurfaceTests: XCTestCase {
  func testNativePasteboardDropMovesBrowserBeforeSourceCompletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-drop-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    defer { store.workspace.browser.shutdown(); try? FileManager.default.removeItem(at: root) }
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let browser = store.workspace.browser.selected
    store.beginWorkspaceTabDrag(tab.id)
    let session = try XCTUnwrap(store.workspaceTabDragSessionID)
    let completion = TabDragCompletion(id: session) { store.endWorkspaceTabDrag(session: $0) }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    XCTAssertTrue(board.writeObjects([WorkspaceTabDragToken.encode(tab.id) as NSString]))
    let view = ContentTabDropSurface.DropView()
    view.accepts = { value in
      WorkspaceTabDragToken.decode(value).map { store.canMoveWorkspaceTab($0, to: .right) } ?? false
    }
    view.drop = { store.dropWorkspaceTab([$0], to: .right) }
    view.targeted = { if !$0 { store.workspaceTabDropTarget = nil } }
    store.workspaceTabDropTarget = .placement(.right)
    XCTAssertTrue(view.performDrop(from: board, sourceOperations: [.copy, .move]))
    completion.finish()
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .right)
    XCTAssertTrue(store.workspace.browser.selected === browser)
    XCTAssertNil(store.workspaceTabDropTarget)
    XCTAssertNil(store.draggingWorkspaceTabID)
  }

  func testCopyOnlyExternalTextAndInvalidTokenNeverReachDrop() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let view = ContentTabDropSurface.DropView()
    view.accepts = { $0 == "valid" }
    view.drop = { _ in XCTFail("Invalid drop must not mutate content"); return true }
    board.setString("valid", forType: .string)
    XCTAssertFalse(view.performDrop(from: board, sourceOperations: .copy))
    board.clearContents()
    board.setString("external text", forType: .string)
    XCTAssertFalse(view.performDrop(from: board, sourceOperations: [.copy, .move]))
    board.clearContents()
    XCTAssertFalse(view.performDrop(from: board, sourceOperations: .move))
  }

  func testDismantledTargetRejectsPendingDrop() {
    let view = ContentTabDropSurface.DropView()
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("valid", forType: .string)
    view.accepts = { _ in true }
    view.drop = { _ in XCTFail("Removed target must not act"); return true }
    ContentTabDropSurface.dismantleNSView(view, coordinator: ())
    XCTAssertFalse(view.performDrop(from: board, sourceOperations: .move))
  }
}
