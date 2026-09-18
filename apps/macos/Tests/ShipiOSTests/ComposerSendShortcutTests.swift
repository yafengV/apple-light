import XCTest

@testable import ShipiOS

final class ComposerSendShortcutTests: XCTestCase {
  func testAllThreeSendModesDistinguishSingleAndMultilineReturn() {
    XCTAssertTrue(ComposerSendShortcut.enter.sendsOnPlainReturn("one\ntwo"))
    XCTAssertFalse(ComposerSendShortcut.commandEnter.sendsOnPlainReturn("one"))
    XCTAssertTrue(ComposerSendShortcut.commandEnterForMultiline.sendsOnPlainReturn("one"))
    XCTAssertFalse(ComposerSendShortcut.commandEnterForMultiline.sendsOnPlainReturn("one\ntwo"))
  }

  func testLegacyBooleanMigratesOnceWithoutOverwritingNewPreference() {
    let suite = "ComposerSendShortcutTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: ComposerSendShortcut.legacyKey)
    XCTAssertEqual(ComposerSendShortcut.stored(defaults: defaults), .enter)
    ComposerSendShortcut.migrate(defaults: defaults)
    XCTAssertEqual(
      defaults.string(forKey: ComposerSendShortcut.storageKey),
      ComposerSendShortcut.enter.rawValue)
    defaults.set(
      ComposerSendShortcut.commandEnterForMultiline.rawValue,
      forKey: ComposerSendShortcut.storageKey)
    defaults.set(false, forKey: ComposerSendShortcut.legacyKey)
    ComposerSendShortcut.migrate(defaults: defaults)
    XCTAssertEqual(
      ComposerSendShortcut.stored(defaults: defaults), .commandEnterForMultiline)
  }
}
