import AppKit
import XCTest
@testable import ShipiOS

final class GlobalDictationIndicatorTests: XCTestCase {
  func testStatusMatchesGlobalSessionLifecycle() {
    XCTAssertEqual(GlobalDictationIndicatorState.resolve(hasHotkey: false,
      target: nil, phase: .idle, hasError: false), .hidden)
    XCTAssertEqual(GlobalDictationIndicatorState.resolve(hasHotkey: true,
      target: nil, phase: .idle, hasError: false), .idle)
    XCTAssertEqual(GlobalDictationIndicatorState.resolve(hasHotkey: true,
      target: "global-dictation:one", phase: .requestingAccess, hasError: false), .initializing)
    XCTAssertEqual(GlobalDictationIndicatorState.resolve(hasHotkey: true,
      target: "global-dictation:one", phase: .listening, hasError: false), .listening)
    XCTAssertEqual(GlobalDictationIndicatorState.resolve(hasHotkey: true,
      target: "global-dictation:one", phase: .finishing, hasError: false), .transcribing)
    XCTAssertEqual(GlobalDictationIndicatorState.resolve(hasHotkey: true,
      target: nil, phase: .idle, hasError: true), .error)
  }

  @MainActor func testFloatingWindowIsNonActivatingAndErrorAllowsRecoveryClick() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var preferences = store.voicePreferences
    preferences.globalHoldHotkey = ShortcutBinding("⌃")
    store.voicePreferences = preferences
    let controller = GlobalDictationIndicatorController(store: store)
    defer { controller.hide() }
    let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "全局听写" })
    XCTAssertTrue(panel.isVisible)
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertEqual(panel.level, .floating)
    XCTAssertEqual(panel.frame.width, GlobalDictationIndicatorController.windowSize.width,
      accuracy: 1)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
      XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY
        + GlobalDictationIndicatorController.bottomInset, accuracy: 1)
    }
    controller.showError("无法写入目标输入框", transcript: "这是一条听写")
    XCTAssertFalse(panel.ignoresMouseEvents)
    XCTAssertFalse(panel.isKeyWindow)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_GLOBAL_DICTATION_RENDER_PATH"],
      let host = panel.contentView {
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    controller.clearError()
    XCTAssertTrue(panel.ignoresMouseEvents)
    preferences.globalHoldHotkey = nil
    store.voicePreferences = preferences
    controller.refresh()
    XCTAssertFalse(panel.isVisible, "The idle reminder must disappear when both hotkeys are off")
    await store.shutdown()
  }
}
