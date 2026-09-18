import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsConfirmationFocusTests: XCTestCase {
  func testReturnRunsOnlyForDismissalOnOwningPageAndWithoutAnotherOverlay() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.openSettings(.memories)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    var restored = 0
    let host = NSHostingView(rootView: FocusReturnProbe(store: store) { restored += 1 })
    window.contentView = host
    func settle() async throws {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(60))
    }
    let request = MemoryDeletionRequest(kind: .single, items: [SavedMemory(text: "test")])
    try await settle()
    XCTAssertEqual(restored, 0, "Mounting a page must not request focus")
    store.memoryDeletion = request
    try await settle()
    XCTAssertEqual(restored, 0)
    store.memoryDeletion = nil
    try await settle()
    XCTAssertEqual(restored, 1)

    store.memoryDeletion = request
    try await settle()
    store.settingsPage = .general
    store.memoryDeletion = nil
    try await settle()
    XCTAssertEqual(restored, 1, "Retained hidden pages must not steal focus")

    store.settingsPage = .memories
    store.memoryDeletion = request
    try await settle()
    store.memoryDeletion = nil
    store.shortcutResetRequested = true
    try await settle()
    XCTAssertEqual(restored, 1, "A new confirmation owns focus")
    store.shortcutResetRequested = false
    store.memoryDeletion = request
    try await settle()
    store.memoryDeletion = nil
    store.presentedOverlay = .commands
    try await settle()
    XCTAssertEqual(restored, 1, "Global overlays also own focus")
    store.presentedOverlay = nil
    store.memoryDeletion = request
    try await settle()
    store.memoryDeletion = nil
    store.closeSettings()
    try await settle()
    XCTAssertEqual(restored, 1)
  }
}

private struct FocusReturnProbe: View {
  let store: WorkspaceStore
  let restore: () -> Void
  var body: some View {
    Text("Focus return test")
      .onSettingsConfirmationDismissal(store.memoryDeletion != nil, store: store,
        page: .memories, restore: restore)
  }
}
