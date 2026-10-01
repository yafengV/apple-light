import AppKit
import Speech
import SwiftUI
import XCTest

@testable import ShipiOS

final class VoiceSettingsTests: XCTestCase {
  func testDictionaryNormalizesAndPersistsWithLegacyDefaults() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertNil(legacy.voicePreferences.dictationLocaleIdentifier)
    XCTAssertTrue(legacy.voicePreferences.dictationDictionary.isEmpty)

    var library = WorkspaceLibrary()
    library.voicePreferences = VoicePreferences(dictationLocaleIdentifier: " zh-CN ",
      dictationDictionary: [" ShipiOS ", "shipios", "Xcode", " "])
    XCTAssertEqual(library.voicePreferences.dictationLocaleIdentifier, "zh-CN")
    XCTAssertEqual(library.voicePreferences.dictationDictionary, ["ShipiOS", "Xcode"])
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.voicePreferences, library.voicePreferences)
  }

  @MainActor func testDictionaryEntersOnDeviceRecognitionRequest() {
    let request = SpeechDictation.recognitionRequest(dictionary: ["ShipiOS", "Xcode"])
    XCTAssertTrue(request.requiresOnDeviceRecognition)
    XCTAssertEqual(request.taskHint, .dictation)
    XCTAssertEqual(request.contextualStrings, ["ShipiOS", "Xcode"])
  }

  func testVoicePageAndSearchTargetsAreVisible() {
    XCTAssertTrue(SettingsNavigation.pages.contains(.voice))
    XCTAssertEqual(SettingsSearch.results(for: "听写词典").map(\.field), [.voiceDictionary])
    XCTAssertEqual(SettingsSearch.results(for: "麦克风").map(\.field), [.voiceMicrophone])
  }

  @MainActor func testVoiceSettingsPageRenders() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
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
}
