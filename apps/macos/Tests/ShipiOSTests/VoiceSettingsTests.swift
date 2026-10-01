import AppKit
import Speech
import SwiftUI
import XCTest

@testable import ShipiOS

final class VoiceSettingsTests: XCTestCase {
  func testDictionaryNormalizesAndPersistsWithLegacyDefaults() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertNil(legacy.voicePreferences.dictationLocaleIdentifier)
    XCTAssertNil(legacy.voicePreferences.microphoneDeviceID)
    XCTAssertNil(legacy.voicePreferences.globalHoldHotkey)
    XCTAssertNil(legacy.voicePreferences.globalToggleHotkey)
    XCTAssertTrue(legacy.voicePreferences.dictationDictionary.isEmpty)

    let longPhrase = String(repeating: "词", count: 101)
    var library = WorkspaceLibrary()
    library.voicePreferences = VoicePreferences(dictationLocaleIdentifier: " zh-CN ",
      microphoneDeviceID: " selected-microphone ",
      globalHoldHotkey: ShortcutBinding("⌃⌥H"),
      globalToggleHotkey: ShortcutBinding("⌃⌥D"),
      dictationDictionary: [" ShipiOS ", "shipios", "Xcode", " ", longPhrase])
    XCTAssertEqual(library.voicePreferences.dictationLocaleIdentifier, "zh-CN")
    XCTAssertEqual(library.voicePreferences.microphoneDeviceID, "selected-microphone")
    XCTAssertEqual(library.voicePreferences.globalHoldHotkey, ShortcutBinding("⌃⌥H"))
    XCTAssertEqual(library.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥D"))
    XCTAssertEqual(library.voicePreferences.dictationDictionary,
      ["ShipiOS", "shipios", "Xcode", longPhrase])
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.voicePreferences, library.voicePreferences)
  }

  func testBareModifierVoiceBindingsPersistIndependently() throws {
    var library = WorkspaceLibrary()
    library.voicePreferences = VoicePreferences(globalHoldHotkey: ShortcutBinding("⌃"),
      globalToggleHotkey: ShortcutBinding("⌥⇧"))
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.voicePreferences.globalHoldHotkey, ShortcutBinding("⌃"))
    XCTAssertEqual(restored.voicePreferences.globalToggleHotkey, ShortcutBinding("⌥⇧"))
  }

  @MainActor func testDictionaryEntersOnDeviceRecognitionRequest() {
    let request = SpeechDictation.recognitionRequest(dictionary: ["ShipiOS", "Xcode"])
    XCTAssertTrue(request.requiresOnDeviceRecognition)
    XCTAssertEqual(request.taskHint, .dictation)
    XCTAssertEqual(request.contextualStrings, ["ShipiOS", "Xcode"])
  }

  @MainActor func testGlobalToggleHotkeyRefreshesOnlyWhenBindingChanges() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var refreshes = 0
    store.globalDictationHotkeyChangeHandler = { refreshes += 1 }
    var preferences = store.voicePreferences
    preferences.dictationLocaleIdentifier = "en-US"
    store.voicePreferences = preferences
    XCTAssertEqual(refreshes, 0)
    preferences.globalToggleHotkey = ShortcutBinding("⌃⌥D")
    store.voicePreferences = preferences
    XCTAssertEqual(refreshes, 1)
    store.voicePreferences = preferences
    XCTAssertEqual(refreshes, 1)
    preferences.globalToggleHotkey = nil
    store.voicePreferences = preferences
    XCTAssertEqual(refreshes, 2)
    preferences.globalHoldHotkey = ShortcutBinding("⌃⌥H")
    store.voicePreferences = preferences
    XCTAssertEqual(refreshes, 3)
    await store.shutdown()
  }

  func testVoicePageAndSearchTargetsAreVisible() {
    XCTAssertTrue(SettingsNavigation.pages.contains(.voice))
    XCTAssertEqual(SettingsSearch.results(for: "听写词典").map(\.field), [.voiceDictionary])
    XCTAssertEqual(SettingsSearch.results(for: "麦克风").map(\.field), [.voiceMicrophone])
    XCTAssertEqual(SettingsSearch.results(for: "切换听写快捷键").map(\.field), [.voiceToggleHotkey])
    XCTAssertEqual(SettingsSearch.results(for: "按住听写快捷键").map(\.field), [.voiceHoldHotkey])
  }

  @MainActor func testVoiceSettingsPageRenders() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var preferences = store.voicePreferences
    preferences.globalHoldHotkey = ShortcutBinding("⌃")
    preferences.globalToggleHotkey = ShortcutBinding("⌥⇧")
    store.voicePreferences = preferences
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 650),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: VoiceSettingsView(store: store)
      .environment(\.appAppearance, store.appearance))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    XCTAssertEqual(host.bounds.width, 760, accuracy: 1)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_VOICE_SETTINGS_RENDER_PATH"] {
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    window.close()
    await store.shutdown()
  }

  @MainActor func testDisconnectedMicrophoneCanReturnToSystemDefault() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var preferences = store.voicePreferences
    preferences.microphoneDeviceID = "missing-audio-device"
    store.voicePreferences = preferences
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 650),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: VoiceSettingsView(store: store)
      .environment(\.appAppearance, store.appearance))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    let microphone = try XCTUnwrap(findMenu(in: host, label: "麦克风"))
    XCTAssertEqual(microphone.titleOfSelectedItem, "所选麦克风已断开")
    XCTAssertFalse(microphone.selectedItem?.isEnabled ?? true)
    microphone.selectItem(at: 0)
    microphone.sendAction(microphone.action, to: microphone.target)
    XCTAssertNil(store.voicePreferences.microphoneDeviceID)
    window.close()
    await store.shutdown()
  }

  @MainActor private func findMenu(in view: NSView, label: String) -> SettingsMenuControl? {
    if let menu = view as? SettingsMenuControl, menu.accessibilityLabel() == label { return menu }
    return view.subviews.lazy.compactMap { self.findMenu(in: $0, label: label) }.first
  }
}
