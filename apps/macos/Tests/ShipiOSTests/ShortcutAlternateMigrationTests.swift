import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ShortcutAlternateMigrationTests: XCTestCase {
  private func preferences() -> ShortcutPreferences {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
  }
  private func legacy(_ overrides: [String: [ShortcutBinding]]) -> ShortcutPreferencesSnapshot {
    var snapshot = ShortcutPreferencesSnapshot(primaryNumberShortcutTarget: .sidebar, overrides: overrides,
      externalBrowserLinkShortcut: .unassigned)
    snapshot.version = 1
    return snapshot
  }

  func testCurrentPublicRegistryHasTwoBindingsOnOneCommandEach() throws {
    struct Reference: Decodable {
      struct Command: Decodable { let id: String; let shipiosID: String; let defaults: [String] }
      let commands: [Command]
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "shortcut_alternates_reference_690",
      withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    XCTAssertEqual(reference.commands.map(\.id), ["openCommandMenu", "newTask"])
    let preferences = preferences()
    for entry in reference.commands {
      let command = try XCTUnwrap(DesktopCommand.all.first { $0.id == entry.shipiosID })
      let defaults = entry.defaults.map { ShortcutBinding($0.replacingOccurrences(of: "CmdOrCtrl+", with: "⌘")
        .replacingOccurrences(of: "Shift+", with: "⇧")) }
      XCTAssertEqual(command.defaultBindings, defaults)
      XCTAssertEqual(preferences.bindings(command.id), defaults)
      XCTAssertFalse(DesktopCommand.all.contains { $0.id == command.id + "-alternate" })
    }
  }

  func testRemoveAndResetAlternateOnSameRowWithoutChangingPrimary() throws {
    let preferences = preferences()
    try preferences.replace(ShortcutBinding("⌘⇧P"), with: nil, for: "palette")
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌘K")])
    try preferences.reset("palette")
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌘K"), ShortcutBinding("⌘⇧P")])
    try preferences.set(nil, for: "palette")
    XCTAssertFalse(preferences.matches("palette", ShortcutBinding("⌘K")))
    XCTAssertFalse(preferences.matches("palette", ShortcutBinding("⌘⇧P")))
  }

  func testOldPrimaryEditRetainsUntouchedAlternate() throws {
    let preferences = preferences()
    try preferences.restore(legacy(["palette": [ShortcutBinding("⌃⌥K")]]))
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌃⌥K"), ShortcutBinding("⌘⇧P")])
    XCTAssertEqual(preferences.primaryNumberShortcutTarget, .sidebar)
    XCTAssertEqual(preferences.snapshot.version, 3)
  }

  func testOldAlternateEditRetainsUntouchedPrimaryAndMigratesBothCommands() throws {
    let preferences = preferences()
    try preferences.restore(legacy(["palette-alternate": [ShortcutBinding("⌃⌥P")],
      "new-alternate": [ShortcutBinding("⌃⌥N")]]))
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌘K"), ShortcutBinding("⌃⌥P")])
    XCTAssertEqual(preferences.bindings("new"), [ShortcutBinding("⌘N"), ShortcutBinding("⌃⌥N")])
    XCTAssertNil(preferences.overrides["palette-alternate"])
    XCTAssertNil(preferences.overrides["new-alternate"])
  }

  func testEachOldUnbindingAndBothUnboundRemainUnbound() throws {
    let preferences = preferences()
    try preferences.restore(legacy(["palette": []]))
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌘⇧P")])
    try preferences.restore(legacy(["palette-alternate": []]))
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌘K")])
    try preferences.restore(legacy(["palette": [], "palette-alternate": []]))
    XCTAssertTrue(preferences.bindings("palette").isEmpty)
  }

  func testMigrationDoesNotReintroduceDefaultsAssignedToAnotherCommand() throws {
    let preferences = preferences()
    try preferences.restore(legacy(["palette-alternate": [], "search": [ShortcutBinding("⌘K")]]))
    XCTAssertTrue(preferences.bindings("palette").isEmpty)
    XCTAssertEqual(preferences.bindings("search"), [ShortcutBinding("⌘K")])
    XCTAssertNil(preferences.conflict(for: ShortcutBinding("⌘K"), excluding: "search"))
  }

  func testUntouchedPairKeepsDefaultsWithoutBecomingCustomized() throws {
    let preferences = preferences()
    try preferences.restore(legacy([:]))
    XCTAssertFalse(preferences.isCustomized("palette"))
    XCTAssertFalse(preferences.isCustomized("new"))
    XCTAssertEqual(preferences.bindings("new"), [ShortcutBinding("⌘N"), ShortcutBinding("⌘⇧O")])
  }

  func testVersionTwoReloadNeverAddsRemovedDefaultAndUnknownVersionPreservesState() throws {
    let preferences = preferences()
    try preferences.restore(legacy(["palette-alternate": []]))
    var versionTwo = preferences.snapshot; versionTwo.version = 2
    let saved = try JSONEncoder().encode(versionTwo)
    let decoded = try JSONDecoder().decode(ShortcutPreferencesSnapshot.self, from: saved)
    try preferences.restore(decoded)
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌘K")])
    var unsupported = decoded; unsupported.version = 99; unsupported.overrides = [:]
    XCTAssertThrowsError(try preferences.restore(unsupported))
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌘K")])
  }

  func testMigratedAlternateParticipatesInConflictChecksAndKeySearch() throws {
    let preferences = preferences()
    try preferences.restore(legacy(["palette-alternate": [ShortcutBinding("⌃⌥Y")]]))
    XCTAssertThrowsError(try preferences.set(ShortcutBinding("⌃⌥Y"), for: "search"))
    let editor = ShortcutSettingsState(); editor.toggleSearchMode()
    editor.receiveSearch(ShortcutBinding("⌃⌥Y"), sessionID: editor.searchCaptureID)
    let matches = DesktopCommand.all.filter { editor.matches($0, preferences: preferences) }
    XCTAssertEqual(matches.map(\.id), ["palette"])
  }

  func testBothDefaultBindingsRouteToSameFocusedWindowCommand() throws {
    let preferences = preferences()
    var invoked: [String] = []
    let context = TaskWindowCommandContext(enabled: ["palette", "new"], perform: { invoked.append($0) })
    for key in ["⌘K", "⌘⇧P"] {
      let id = try XCTUnwrap(context.command(for: ShortcutBinding(key), shortcuts: preferences))
      XCTAssertEqual(id, "palette"); XCTAssertTrue(context.execute(id))
    }
    for key in ["⌘N", "⌘⇧O"] {
      let id = try XCTUnwrap(context.command(for: ShortcutBinding(key), shortcuts: preferences))
      XCTAssertEqual(id, "new"); XCTAssertTrue(context.execute(id))
    }
    XCTAssertEqual(invoked, ["palette", "palette", "new", "new"])
  }

  func testLegacyDictionaryLoadsWithoutWritingAndNextEditSavesCurrentVersion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("shortcuts.json")
    let original = try JSONEncoder().encode(["palette-alternate": [ShortcutBinding("⌃⌥Y")]])
    try original.write(to: file)
    let preferences = ShortcutPreferences(file: file)
    XCTAssertEqual(try Data(contentsOf: file), original)
    XCTAssertEqual(preferences.bindings("palette"), [ShortcutBinding("⌘K"), ShortcutBinding("⌃⌥Y")])
    try preferences.replace(ShortcutBinding("⌘K"), with: nil, for: "palette")
    let reloaded = ShortcutPreferences(file: file)
    XCTAssertNil(reloaded.loadError)
    XCTAssertEqual(reloaded.bindings("palette"), [ShortcutBinding("⌃⌥Y")])
    XCTAssertEqual(try JSONDecoder().decode(ShortcutPreferencesSnapshot.self,
      from: Data(contentsOf: file)).version, 3)
  }

  func testTwelveLegacyAlternatesArePreservedAndCanBeReducedOrReplaced() throws {
    let preferences = preferences()
    let values = (1...9).map { ShortcutBinding("⌃⌥\($0)") }
      + ["⌃⌥Y", "⌃⌥Z", "⌃⌥U"].map(ShortcutBinding.init)
    try preferences.restore(legacy(["palette": Array(values.prefix(6)),
      "palette-alternate": Array(values.suffix(6))]))
    XCTAssertEqual(preferences.bindings("palette"), values)
    XCTAssertThrowsError(try preferences.replace(nil, with: ShortcutBinding("⌃⌥I"), for: "palette"))
    try preferences.replace(values[0], with: ShortcutBinding("⌃⌥I"), for: "palette")
    try preferences.replace(values[1], with: nil, for: "palette")
    XCTAssertEqual(preferences.bindings("palette").count, 11)
    XCTAssertEqual(preferences.binding("palette"), ShortcutBinding("⌃⌥I"))
  }

  func testDuplicateLegacyValuesAreDeduplicatedWithoutDroppingOtherBindings() throws {
    let preferences = preferences()
    let first = ShortcutBinding("⌃⌥Y"), second = ShortcutBinding("⌃⌥Z")
    try preferences.restore(legacy(["palette": [first], "palette-alternate": [first, second]]))
    XCTAssertEqual(preferences.bindings("palette"), [first, second])
  }

  func testWorkspaceMigrationSavesOneCanonicalSnapshotAndReloadsIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("workspace.json")
    var library = WorkspaceLibrary()
    library.shortcutPreferences = legacy(["palette": [], "palette-alternate": [ShortcutBinding("⌃⌥Y")]])
    try library.save(to: file)
    let store = WorkspaceStore(dataRoot: root); await store.restore()
    XCTAssertEqual(store.shortcuts.bindings("palette"), [ShortcutBinding("⌃⌥Y")])
    // Workspace restoration also saves tab/appearance recovery. Only the
    // shortcut migration is deferred until an explicit settings save.
    let beforeEdit = try XCTUnwrap(WorkspaceLibrary.load(from: file).shortcutPreferences)
    XCTAssertEqual(beforeEdit.version, 1)
    XCTAssertEqual(beforeEdit.overrides, library.shortcutPreferences?.overrides)
    try store.shortcuts.replace(ShortcutBinding("⌃⌥Y"), with: nil, for: "palette")
    let saved = try XCTUnwrap(WorkspaceLibrary.load(from: file).shortcutPreferences)
    XCTAssertEqual(saved.version, 3); XCTAssertNil(saved.overrides["palette-alternate"])
    XCTAssertEqual(saved.overrides["palette"], [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("shortcuts.json").path))
    store.shortcuts.reload()
    XCTAssertNil(store.shortcuts.loadError); XCTAssertTrue(store.shortcuts.bindings("palette").isEmpty)
    let reopened = WorkspaceStore(dataRoot: root); await reopened.restore()
    XCTAssertTrue(reopened.shortcuts.bindings("palette").isEmpty)
    await store.shutdown(); await reopened.shutdown()
  }

  func testFailedWorkspaceSaveLeavesMigratedBindingsAndStoredLegacyDataIntact() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("workspace.json")
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let original = legacy(["new-alternate": []])
    store.library.shortcutPreferences = original
    try store.shortcuts.restore(original)
    try store.library.save(to: file)
    let backup = root.appendingPathComponent("backup.json")
    try FileManager.default.moveItem(at: file, to: backup)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.shortcuts.set(nil, for: "new"))
    XCTAssertEqual(store.shortcuts.bindings("new"), [ShortcutBinding("⌘N")])
    XCTAssertEqual(store.library.shortcutPreferences?.version, 1)
    XCTAssertEqual(try WorkspaceLibrary.load(from: backup).shortcutPreferences?.version, 1)
  }

  func testMainWindowAlternateUsesCanonicalActionAndCannotEscapeUnbinding() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌘⇧P")))
    XCTAssertTrue(store.showingCommands)
    store.showingCommands = false
    try store.shortcuts.replace(ShortcutBinding("⌘⇧P"), with: nil, for: "palette")
    XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌘⇧P")))
    XCTAssertFalse(store.showingCommands)
  }

  func testMountedPageEditsSecondBindingThroughNativeRecorderAndKeepsPrimary() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.openSettings(.shortcuts)
    let editor = ShortcutSettingsState()
    let window = Window(contentRect: .init(x: 0, y: 0, width: 760, height: 620),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
    let host = NSHostingView(rootView: ShortcutSettingsView(store: store, editor: editor)
      .environment(\.appAppearance, store.appearance))
    window.contentView = host
    for (id, primary, alternate) in [("palette", "⌘K", "⌘⇧P"), ("new", "⌘N", "⌘⇧O")] {
      editor.query = try XCTUnwrap(DesktopCommand.all.first { $0.id == id }).title
      try await settle(host)
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SHORTCUT_ALTERNATES_RENDER_DIR"] {
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: output.appendingPathComponent("\(id).png"))
      }
      editor.begin(id, replacing: ShortcutBinding(alternate)); try await settle(host)
      let field = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
      XCTAssertTrue(window.makeFirstResponder(field)); XCTAssertEqual(store.shortcutCaptureCount, 1)
      let key = id == "palette" ? "y" : "z"
      field.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.control, .option], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
        keyCode: id == "palette" ? 16 : 6)))
      try await settle(host)
      XCTAssertNil(editor.capture); XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertEqual(store.shortcuts.bindings(id), [ShortcutBinding(primary), ShortcutBinding("⌃⌥\(key)")])
      XCTAssertFalse(store.shortcuts.matches(id, ShortcutBinding(alternate)))
      XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
        .shortcutPreferences?.version, 3)
      XCTAssertTrue(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.isEmpty)
    }
    XCTAssertFalse(window.isVisible)
  }

  private final class Window: NSWindow { override var isKeyWindow: Bool { true } }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(180)); host.layoutSubtreeIfNeeded()
  }
}
