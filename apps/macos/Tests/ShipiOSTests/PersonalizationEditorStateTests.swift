import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PersonalizationEditorStateTests: XCTestCase {
  func testEditorAppearsOnlyAfterSuccessfulLoadAndFailedSaveKeepsItEditable() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PersonalizationSettingsView(store: store))
    window.contentView = host
    host.frame.size = .init(width: 700, height: 600)
    func settle(_ name: String) async throws {
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: directory.appendingPathComponent("instructions-" + name + ".png"))
      }
    }
    func editors(_ view: NSView) -> [SettingsTextEditor.TextView] {
      (view as? SettingsTextEditor.TextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }
    store.personalizationLoading = true
    try await settle("loading")
    XCTAssertTrue(editors(host).isEmpty)
    XCTAssertFalse(store.canSavePersonalizationEdits)
    store.personalizationLoading = false
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0xff]).write(to: root.appendingPathComponent("AGENTS.md"))
    await store.loadPersonalization()
    try await settle("load-error")
    XCTAssertNotNil(store.personalizationError)
    XCTAssertTrue(editors(host).isEmpty)
    XCTAssertFalse(store.canSavePersonalizationEdits)

    // Retrying a repaired file uses the same loaded/error state as the button.
    try PersonalizationStorage.saveInstructions("已修复的指令", root: root)
    await store.loadPersonalization()
    try await settle("ready")
    let editor = try XCTUnwrap(editors(host).first)
    XCTAssertEqual(editors(host).count, 1)
    XCTAssertEqual(editor.string, "已修复的指令")
    XCTAssertTrue(editor.isEditable)
    XCTAssertNil(store.personalizationError)

    store.personalizationDraft = String(repeating: "中", count: 30_000)
    XCTAssertFalse(store.savePersonalizationEdits())
    try await settle("save-error")
    XCTAssertTrue(editors(host).first === editor)
    XCTAssertTrue(editor.isEditable)
    XCTAssertEqual(editor.string.count, 30_000)
    XCTAssertEqual(store.customInstructions, "已修复的指令")
    XCTAssertTrue(store.canSavePersonalizationEdits)
    store.personalizationDraft = "更正后的指令"
    XCTAssertTrue(store.savePersonalizationEdits())
    try await settle("saved")
    XCTAssertEqual(editor.string, "更正后的指令")
    XCTAssertNil(store.personalizationError)
    XCTAssertFalse(store.canSavePersonalizationEdits)
  }
}
