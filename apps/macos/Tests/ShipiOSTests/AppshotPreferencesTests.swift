import AppKit
import XCTest

@testable import ShipiOS

final class AppshotPreferencesTests: XCTestCase {
  func testTwoCommandKeysTriggerOnlyDuringShortOverlap() {
    var chord = AppshotCommandChord()
    XCTAssertFalse(chord.flagsChanged(keyCode: 55, modifierDown: true, hotkey: .doubleCommand, at: 1))
    XCTAssertTrue(chord.flagsChanged(keyCode: 54, modifierDown: true, hotkey: .doubleCommand, at: 1.2))
    XCTAssertFalse(chord.flagsChanged(keyCode: 54, modifierDown: true, hotkey: .doubleCommand, at: 1.3))
    XCTAssertFalse(chord.flagsChanged(keyCode: 55, modifierDown: false, hotkey: .doubleCommand, at: 1.4))
    XCTAssertFalse(chord.flagsChanged(keyCode: 54, modifierDown: true, hotkey: .doubleCommand, at: 2))
    XCTAssertTrue(chord.flagsChanged(keyCode: 55, modifierDown: true, hotkey: .doubleCommand, at: 2.1))
  }

  func testSlowOverlapDoesNotTrigger() {
    var chord = AppshotCommandChord()
    XCTAssertFalse(chord.flagsChanged(keyCode: 55, modifierDown: true, hotkey: .doubleCommand, at: 1))
    XCTAssertFalse(chord.flagsChanged(keyCode: 54, modifierDown: true, hotkey: .doubleCommand, at: 2))
  }

  func testOptionAndShiftPairsUseTheirOwnPhysicalKeys() {
    var chord = AppshotCommandChord()
    XCTAssertFalse(chord.flagsChanged(keyCode: 58, modifierDown: true, hotkey: .doubleOption, at: 1))
    XCTAssertTrue(chord.flagsChanged(keyCode: 61, modifierDown: true, hotkey: .doubleOption, at: 1.1))
    XCTAssertFalse(chord.flagsChanged(keyCode: 58, modifierDown: false, hotkey: .doubleOption, at: 1.2))
    XCTAssertFalse(chord.flagsChanged(keyCode: 56, modifierDown: true, hotkey: .doubleShift, at: 2))
    XCTAssertTrue(chord.flagsChanged(keyCode: 60, modifierDown: true, hotkey: .doubleShift, at: 2.1))
    XCTAssertFalse(chord.flagsChanged(keyCode: 55, modifierDown: true, hotkey: .none, at: 3))
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
    XCTAssertTrue(AppshotDestination.lastChat.shouldStartNewChat(
      hasCurrentChat: true, focusedRecently: true, canAcceptShortcut: false))
  }

  func testPreferencesSurviveRoundTripAndLegacyLibraryGetsDefaults() throws {
    var library = WorkspaceLibrary()
    library.appshotHotkey = .doubleOption
    library.appshotDestination = .newChat
    library.appshotSoundEnabled = false
    library.hasAcceptedAppshotIntro = true
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.appshotHotkey, .doubleOption)
    XCTAssertEqual(restored.appshotDestination, .newChat)
    XCTAssertFalse(restored.appshotSoundEnabled)
    XCTAssertTrue(restored.hasAcceptedAppshotIntro)
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertEqual(legacy.appshotHotkey, .doubleCommand)
    XCTAssertEqual(legacy.appshotDestination, .automatic)
    XCTAssertTrue(legacy.appshotSoundEnabled)
    XCTAssertFalse(legacy.hasAcceptedAppshotIntro)
    let disabledLegacy = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: Data("{\"appshotHotkeyEnabled\":false}".utf8))
    XCTAssertEqual(disabledLegacy.appshotHotkey, .none)
  }

  func testAppshotSettingsAreInsideSettingsNavigation() {
    XCTAssertTrue(SettingsNavigation.pages.contains(.appshots))
    XCTAssertEqual(SettingsSearchField.appshotDestination.page, .appshots)
    XCTAssertEqual(SettingsSearch.results(for: "Appshot 发送目标").map(\.field), [.appshotDestination])
    XCTAssertTrue(SettingsSearch.results(for: "Option ⌥").contains { $0.field == .appshotHotkey })
    XCTAssertTrue(SettingsSearch.results(for: "Shift ⇧").contains { $0.field == .appshotHotkey })
  }

  @MainActor func testFirstUseWaitsForConsentAndCancelDoesNotCapture() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var openedMainWindow = 0
    store.showMainWindowHandler = { openedMainWindow += 1 }
    await store.captureAppshot(draft: "first-use", mode: .shortcut)
    XCTAssertEqual(store.appshotIntroRequest?.draftKey, "first-use")
    XCTAssertEqual(store.appshotIntroRequest?.mode, .shortcut)
    XCTAssertEqual(openedMainWindow, 1)
    XCTAssertFalse(store.importingImages)
    store.cancelAppshotIntro()
    XCTAssertNil(store.appshotIntroRequest)
    XCTAssertFalse(store.library.hasAcceptedAppshotIntro)
    XCTAssertNil(store.library.draftImages["first-use"])
    await store.captureAppshot(draft: "first-use")
    XCTAssertNotNil(store.appshotIntroRequest)
    XCTAssertEqual(store.appshotIntroRequest?.mode, .manual)
    store.cancelAppshotIntro()
    await store.shutdown()
  }

  @MainActor func testGlobalShortcutUsesLastFocusedTaskWindowDraft() async {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks.append(WorkspaceTask(id: "other-task", project: "", title: "Other", runIDs: []))
    let main = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    let taskWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    main.isReleasedWhenClosed = false
    taskWindow.isReleasedWhenClosed = false
    let resources = TaskWindowResources()
    resources.attach(window: taskWindow, from: NSView())
    resources.display("other-task")
    store.taskWindowResources.add(resources)

    let chat = AppshotShortcutChat.resolve(lastWindow: taskWindow, mainWindow: main,
      store: store, popout: nil)
    XCTAssertEqual(chat.draftKey(in: store), "other-task")
    XCTAssertTrue(chat.ownerWindow === taskWindow)
    XCTAssertTrue(chat.hasCurrentChat(in: store))
    XCTAssertTrue(chat.canAcceptShortcut(in: store))
    XCTAssertFalse(chat.shouldStartNewChat(destination: .automatic,
      focusedRecently: true, store: store))
    XCTAssertTrue(chat.shouldStartNewChat(destination: .automatic,
      focusedRecently: false, store: store))

    resources.display(nil)
    let loading = AppshotShortcutChat.resolve(lastWindow: taskWindow, mainWindow: main,
      store: store, popout: nil)
    XCTAssertTrue(loading.ownerWindow === main)
    main.close()
    taskWindow.close()
    await store.shutdown()
  }

  @MainActor func testGlobalMonitorRegistersAfterPermissionAndUnregistersWhenDisabled() {
    let token = NSObject()
    var attempts = 0
    var removals = 0
    var registrationAvailable = false
    let registration = AppshotGlobalMonitorRegistration(register: {
      attempts += 1
      return registrationAvailable ? token : nil
    }, remove: { removed in
      XCTAssertTrue((removed as AnyObject) === token)
      removals += 1
    })
    XCTAssertFalse(registration.refresh(trusted: false))
    XCTAssertEqual(attempts, 0)
    XCTAssertFalse(registration.refresh(trusted: true))
    XCTAssertEqual(attempts, 1, "A failed registration may be retried after app activation")
    registrationAvailable = true
    XCTAssertTrue(registration.refresh(trusted: true))
    XCTAssertTrue(registration.isRegistered)
    XCTAssertEqual(attempts, 2)
    XCTAssertFalse(registration.refresh(trusted: true))
    XCTAssertEqual(attempts, 2, "Do not install duplicate global monitors")
    XCTAssertTrue(registration.refresh(trusted: false))
    XCTAssertEqual(removals, 1)
    XCTAssertTrue(registration.refresh(trusted: true))
    XCTAssertEqual(attempts, 3)
    registration.stop()
    XCTAssertEqual(removals, 2)
  }

  @MainActor func testChangingAppshotHotkeyRefreshesGlobalMonitorOnlyAfterSave() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var changes = 0
    store.appshotHotkeyChangeHandler = { changes += 1 }
    store.appshotHotkey = .doubleOption
    store.appshotHotkey = .doubleOption
    store.appshotHotkey = .none
    XCTAssertEqual(changes, 2)
    XCTAssertEqual(store.appshotHotkey, .none)
    await store.shutdown()
  }
}
