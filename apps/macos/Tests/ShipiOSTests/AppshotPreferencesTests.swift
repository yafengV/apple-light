import XCTest

@testable import ShipiOS

final class AppshotPreferencesTests: XCTestCase {
  func testTwoCommandKeysTriggerOnlyDuringShortOverlap() {
    var chord = AppshotCommandChord()
    XCTAssertFalse(chord.flagsChanged(keyCode: 55, commandDown: true, at: 1))
    XCTAssertTrue(chord.flagsChanged(keyCode: 54, commandDown: true, at: 1.2))
    XCTAssertFalse(chord.flagsChanged(keyCode: 54, commandDown: true, at: 1.3))
    XCTAssertFalse(chord.flagsChanged(keyCode: 55, commandDown: false, at: 1.4))
    XCTAssertFalse(chord.flagsChanged(keyCode: 54, commandDown: true, at: 2))
    XCTAssertTrue(chord.flagsChanged(keyCode: 55, commandDown: true, at: 2.1))
  }

  func testSlowOverlapDoesNotTrigger() {
    var chord = AppshotCommandChord()
    XCTAssertFalse(chord.flagsChanged(keyCode: 55, commandDown: true, at: 1))
    XCTAssertFalse(chord.flagsChanged(keyCode: 54, commandDown: true, at: 2))
  }

  func testDestinationRoutingKeepsUnusedNewComposer() {
    XCTAssertFalse(AppshotDestination.automatic.shouldStartNewChat(
      hasCurrentChat: false, focusedRecently: false))
    XCTAssertFalse(AppshotDestination.automatic.shouldStartNewChat(
      hasCurrentChat: true, focusedRecently: true))
    XCTAssertTrue(AppshotDestination.automatic.shouldStartNewChat(
      hasCurrentChat: true, focusedRecently: false))
    XCTAssertFalse(AppshotDestination.lastChat.shouldStartNewChat(
      hasCurrentChat: true, focusedRecently: false))
    XCTAssertTrue(AppshotDestination.newChat.shouldStartNewChat(
      hasCurrentChat: true, focusedRecently: true))
  }

  func testPreferencesSurviveRoundTripAndLegacyLibraryGetsDefaults() throws {
    var library = WorkspaceLibrary()
    library.appshotHotkeyEnabled = false
    library.appshotDestination = .newChat
    library.appshotSoundEnabled = false
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertFalse(restored.appshotHotkeyEnabled)
    XCTAssertEqual(restored.appshotDestination, .newChat)
    XCTAssertFalse(restored.appshotSoundEnabled)
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(legacy.appshotHotkeyEnabled)
    XCTAssertEqual(legacy.appshotDestination, .automatic)
    XCTAssertTrue(legacy.appshotSoundEnabled)
  }

  func testAppshotSettingsAreInsideSettingsNavigation() {
    XCTAssertTrue(SettingsNavigation.pages.contains(.appshots))
    XCTAssertEqual(SettingsSearchField.appshotDestination.page, .appshots)
    XCTAssertEqual(SettingsSearch.results(for: "Appshot 发送目标").map(\.field), [.appshotDestination])
  }
}
