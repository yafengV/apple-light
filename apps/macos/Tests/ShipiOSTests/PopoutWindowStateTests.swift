import XCTest
@testable import ShipiOS

final class PopoutWindowStateTests: XCTestCase {
  func testHotkeyRestoresLastVisibleSurfaceWithoutCreatingAnotherThread() {
    var state = PopoutWindowState()
    state.toggle()
    XCTAssertEqual(state.visibleSurface, .home)
    state.toggle()
    XCTAssertNil(state.visibleSurface)
    state.openThread("/thread/one")
    state.toggle()
    XCTAssertNil(state.visibleSurface)
    state.toggle()
    XCTAssertEqual(state.visibleSurface, .thread("/thread/one"))
  }

  func testHomeAndThreadNavigationUpdatesRestoreTarget() {
    var state = PopoutWindowState()
    state.openThread("/thread/one")
    state.openThread("/thread/two")
    XCTAssertEqual(state.visibleSurface, .thread("/thread/two"))
    state.openHome()
    state.hide()
    state.toggle()
    XCTAssertEqual(state.visibleSurface, .home)
  }

  func testHidingDoesNotDiscardThreadRoute() {
    var state = PopoutWindowState()
    state.openThread("/thread/one")
    state.hide()
    XCTAssertEqual(state.lastVisibleSurface, .thread("/thread/one"))
    state.toggle()
    XCTAssertEqual(state.visibleSurface, .thread("/thread/one"))
  }

  func testDeletedThreadFallsBackToHomeBeforeHotkeyRestores() {
    var state = PopoutWindowState()
    state.openThread("removed")
    state.hide()
    state.retainThreads(["kept"])
    state.toggle()
    XCTAssertEqual(state.visibleSurface, .home)
  }
}
