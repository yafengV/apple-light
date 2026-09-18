import XCTest

@testable import ShipiOS

final class PanelLayoutTests: XCTestCase {
  func testResizingWindowClampsDisplayedSizesWithoutDestroyingUserPreference() {
    let sizes = WorkspacePanelSizes(inspectorWidth: 700, terminalHeight: 500)
    XCTAssertEqual(sizes.inspector(available: 1_400), 700)
    XCTAssertEqual(sizes.inspector(available: 700), 374)
    XCTAssertEqual(sizes.inspector(available: 1_400), 700)
    XCTAssertEqual(sizes.terminal(available: 900), 500)
    XCTAssertEqual(sizes.terminal(available: 600), 334)
    XCTAssertEqual(sizes.terminal(available: 900), 500)
    XCTAssertEqual(sizes.inspectorWidth, 700)
    XCTAssertEqual(sizes.terminalHeight, 500)
  }

  func testExtremeGeometryNeverCreatesNegativeOrNonFiniteFrames() {
    for available in [-100.0, 0, 150, 300, 600, Double.infinity, Double.nan] {
      let sizes = WorkspacePanelSizes(inspectorWidth: .infinity, terminalHeight: .nan)
      XCTAssertTrue(sizes.inspector(available: available).isFinite)
      XCTAssertTrue(sizes.terminal(available: available).isFinite)
      XCTAssertGreaterThanOrEqual(sizes.inspector(available: available), 0)
      XCTAssertGreaterThanOrEqual(sizes.terminal(available: available), 0)
      if available.isFinite, available >= 0 {
        XCTAssertLessThanOrEqual(sizes.inspector(available: available), available)
        XCTAssertLessThanOrEqual(sizes.terminal(available: available), available)
      }
    }
  }

  func testLegacyRecordsAndSavedDimensionsRoundTrip() throws {
    var library = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(library.panelSizes.isEmpty)
    library.panelSizes["/app"] = WorkspacePanelSizes(inspectorWidth: 400, terminalHeight: 300)
    let data = try JSONEncoder().encode(library)
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: data)
    XCTAssertEqual(restored.panelSizes["/app"], library.panelSizes["/app"])
    XCTAssertEqual(WorkspacePanelSizes().terminal(available: 800), 235)
  }

  @MainActor func testDimensionsAreIndependentPerProjectAndSurviveSettingsAndPanelSwitches() {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/app")
    store.resizeInspector(to: 440)
    store.resizeTerminal(to: 280)
    store.showingInspector = false
    store.showingTerminal = false
    store.openSettings(.appearance)
    store.closeSettings()
    store.showPane("files")
    XCTAssertEqual(store.panelSizes, WorkspacePanelSizes(inspectorWidth: 440, terminalHeight: 280))
    store.project = URL(fileURLWithPath: "/docs")
    XCTAssertEqual(store.panelSizes, WorkspacePanelSizes())
    store.resizeInspector(to: 350)
    store.project = URL(fileURLWithPath: "/app")
    XCTAssertEqual(store.panelSizes.inspectorWidth, 440)
    XCTAssertEqual(store.panelSizes.terminalHeight, 280)
    store.resetInspectorSize()
    XCTAssertNil(store.panelSizes.inspectorWidth)
    XCTAssertEqual(store.panelSizes.terminalHeight, 280)
    store.resetTerminalSize()
    XCTAssertEqual(store.panelSizes, WorkspacePanelSizes())
    store.project = URL(fileURLWithPath: "/docs")
    XCTAssertEqual(store.panelSizes.inspectorWidth, 350)
  }

  @MainActor func testInvalidResizeCannotPoisonPersistedWorkspace() throws {
    let store = WorkspaceStore()
    store.resizeInspector(to: .nan)
    store.resizeTerminal(to: .infinity)
    store.resizeInspector(to: -10)
    store.resizeTerminal(to: -100)
    XCTAssertEqual(store.panelSizes, WorkspacePanelSizes())
    XCTAssertNoThrow(try JSONEncoder().encode(store.library))
  }
}
