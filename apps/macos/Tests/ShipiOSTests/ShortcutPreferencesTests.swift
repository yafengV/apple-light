import AppKit
import XCTest

@testable import ShipiOS

final class ShortcutPreferencesTests: XCTestCase {
  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("shortcuts.json")
  }

  @MainActor func testDefaultsHaveUniqueBindingsAndCommandIDs() {
    let preferences = ShortcutPreferences(file: temporaryFile())
    let commands = DesktopCommand.all
    XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
    let bindings = commands.flatMap(\.defaultBindings)
    XCTAssertEqual(Set(bindings).count, bindings.count)
    XCTAssertEqual(preferences.binding("send"), ShortcutBinding("⌘↵"))
    XCTAssertEqual(preferences.binding("next-task"), ShortcutBinding("⌃⇥"))
    XCTAssertNil(preferences.binding("search"))
    for command in commands {
      for binding in command.defaultBindings { XCTAssertNil(binding.validationMessage(for: command.id), binding.display) }
    }
  }

  @MainActor func testSaveReloadUnbindAndReset() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let preferences = ShortcutPreferences(file: file)
    try preferences.set(ShortcutBinding("⌘⇧L"), for: "search")
    try preferences.set(nil, for: "palette")
    let reloaded = ShortcutPreferences(file: file)
    XCTAssertEqual(reloaded.binding("search"), ShortcutBinding("⌘⇧L"))
    XCTAssertNil(reloaded.binding("palette"))
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    try reloaded.reset("palette")
    XCTAssertEqual(reloaded.binding("palette"), ShortcutBinding("⌘K"))
    try reloaded.resetAll()
    XCTAssertTrue(reloaded.overrides.isEmpty)
    XCTAssertNil(ShortcutPreferences(file: file).binding("search"))
  }

  @MainActor func testConflictsAndTextShortcutsDoNotChangeSavedBindings() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let preferences = ShortcutPreferences(file: file)
    XCTAssertThrowsError(try preferences.set(ShortcutBinding("⌘K"), for: "search"))
    XCTAssertThrowsError(try preferences.set(ShortcutBinding("⌘C"), for: "search"))
    XCTAssertThrowsError(try preferences.set(ShortcutBinding("⇧L"), for: "search"))
    XCTAssertTrue(preferences.overrides.isEmpty)
    try preferences.set(nil, for: "palette")
    try preferences.set(ShortcutBinding("⌘K"), for: "search")
    XCTAssertThrowsError(try preferences.reset("palette"))
    XCTAssertNil(preferences.binding("palette"))
    XCTAssertEqual(preferences.binding("search"), ShortcutBinding("⌘K"))
  }

  @MainActor func testInvalidFileIsNotOverwritten() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("not json".utf8)
    try original.write(to: file)
    let preferences = ShortcutPreferences(file: file)
    XCTAssertNotNil(preferences.loadError)
    XCTAssertThrowsError(try preferences.resetAll())
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  func testCapturedKeysMatchMenuBindings() throws {
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
        characters: "L", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
    XCTAssertEqual(ShortcutBinding(event: event), ShortcutBinding("⌘⇧L"))
    XCTAssertEqual(ShortcutBinding("⌘↵").keyboardShortcut.key, .return)
    XCTAssertEqual(ShortcutBinding("⌃⇥").keyboardShortcut.key, .tab)
  }

  @MainActor func testRetryReadsRepairedFileAndKeepsLastGoodBindingsOnFailure() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("invalid json".utf8).write(to: file)
    let preferences = ShortcutPreferences(file: file)
    XCTAssertNotNil(preferences.loadError)
    let valid = try JSONEncoder().encode(["search": [ShortcutBinding("⌘⇧L")]])
    try valid.write(to: file)
    preferences.reload()
    XCTAssertNil(preferences.loadError)
    XCTAssertEqual(preferences.binding("search"), ShortcutBinding("⌘⇧L"))
    try Data("invalid again".utf8).write(to: file)
    preferences.reload()
    XCTAssertNotNil(preferences.loadError)
    XCTAssertEqual(preferences.binding("search"), ShortcutBinding("⌘⇧L"))
    XCTAssertThrowsError(try preferences.resetAll())
    XCTAssertEqual(try Data(contentsOf: file), Data("invalid again".utf8))
    try valid.write(to: file)
    preferences.reload()
    try preferences.set(nil, for: "search")
    XCTAssertNil(ShortcutPreferences(file: file).binding("search"))
  }
}
