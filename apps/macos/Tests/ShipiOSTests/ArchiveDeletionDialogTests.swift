import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class ArchiveDeletionDialogTests: XCTestCase {
  private func task(_ id: String) -> WorkspaceTask {
    .init(id: id, project: "/project", title: id, runIDs: [], archived: true)
  }

  @MainActor func testCancelAndModalRoutingPreserveSettingsAndDraft() throws {
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    store.openSettings(.archived)
    store.library.tasks = [task("one")]
    store.library.drafts["one"] = "draft"
    store.requestArchiveDeletion(.single, ids: ["one"])
    let request = store.archiveDeletion
    store.requestArchiveDeletion(.all, ids: ["other"])
    XCTAssertEqual(store.archiveDeletion, request)
    for command in DesktopCommand.all {
      XCTAssertFalse(store.commandEnabled(command.id), command.id)
    }
    XCTAssertFalse(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘F"))))
    XCTAssertFalse(store.handleModifiedEscape(try XCTUnwrap(ShortcutBinding("⌘⎋"))))
    store.executeCommand("new")
    store.openSettings(.general)
    store.closeSettings()
    store.setOverlay(.commands, presented: true)
    XCTAssertEqual(store.settingsPage, .archived)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertNil(store.presentedOverlay)
    store.dismissArchiveDeletion()
    XCTAssertNil(store.archiveDeletion)
    XCTAssertEqual(store.library.tasks.map(\.id), ["one"])
    XCTAssertEqual(store.library.drafts["one"], "draft")
    XCTAssertTrue(store.commandEnabled("settings"))
  }

  @MainActor func testFailureKeepsRequestAndRetryDeletesOnlyOriginalEligibleIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("workspace.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.tasks = [task("delete"), task("restored")]
    store.requestArchiveDeletion(.project, ids: ["delete", "restored"])
    let request = store.archiveDeletion
    await store.confirmArchiveDeletion()
    XCTAssertEqual(store.archiveDeletion, request)
    XCTAssertNotNil(store.archivedTaskDeletionError)
    XCTAssertFalse(store.deletingArchive)
    XCTAssertEqual(store.library.tasks.count, 2)
    try FileManager.default.removeItem(at: file)
    XCTAssertTrue(store.restoreArchivedTask("restored"))
    store.library.tasks.append(task("new"))
    await store.confirmArchiveDeletion()
    XCTAssertNil(store.archiveDeletion)
    XCTAssertNil(store.archivedTaskDeletionError)
    XCTAssertFalse(store.deletingArchive)
    XCTAssertEqual(Set(store.library.tasks.map(\.id)), ["restored", "new"])
    XCTAssertEqual(Set(try WorkspaceLibrary.load(from: file).tasks.map(\.id)), ["restored", "new"])
  }

  @MainActor func testBusyIgnoresCancelAndDuplicateConfirmation() async {
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    store.library.tasks = [task("one")]
    store.requestArchiveDeletion(.all, ids: ["one"])
    store.deletingArchive = true
    store.dismissArchiveDeletion()
    await store.confirmArchiveDeletion()
    XCTAssertNotNil(store.archiveDeletion)
    XCTAssertEqual(store.library.tasks.count, 1)
    store.deletingArchive = false
    await store.confirmArchiveDeletion()
    XCTAssertNil(store.archiveDeletion)
    XCTAssertTrue(store.library.tasks.isEmpty)
  }

  @MainActor func testModalKeyboardMapping() throws {
    func event(_ keyCode: UInt16, flags: NSEvent.ModifierFlags = [], characters: String = "") throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
    XCTAssertEqual(ModalKeyboardBridge.key(for: try event(53)), .cancel)
    XCTAssertEqual(ModalKeyboardBridge.key(for: try event(13, flags: .command, characters: "w")), .cancel)
    XCTAssertEqual(ModalKeyboardBridge.key(for: try event(36)), .activate)
    XCTAssertEqual(ModalKeyboardBridge.key(for: try event(49, characters: " ")), .activate)
    XCTAssertEqual(SettingsConfirmationDialog.activationTarget(nil), .cancel)
    XCTAssertEqual(SettingsConfirmationDialog.activationTarget(.cancel), .cancel)
    XCTAssertEqual(SettingsConfirmationDialog.activationTarget(.confirm), .confirm)
    XCTAssertEqual(ModalKeyboardBridge.key(for: try event(76, flags: .numericPad)), .activate)
    XCTAssertEqual(ModalKeyboardBridge.key(for: try event(48)), .next)
    XCTAssertEqual(ModalKeyboardBridge.key(for: try event(48, flags: .shift)), .next)
    XCTAssertNil(ModalKeyboardBridge.key(for: try event(8, flags: .command, characters: "c")))
    XCTAssertNil(ModalKeyboardBridge.key(for: try event(36, flags: .command)))
  }

  @MainActor func testInitialFocusWaitsForNativeCaptureAndCannotRunAfterDismantle() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = NSView()
    window.contentView = view
    var ready = 0
    let coordinator = ModalKeyboardBridge.Coordinator(onReady: { ready += 1 }, action: { _ in })
    coordinator.install(view)
    coordinator.capture(window)
    coordinator.capture(window)
    XCTAssertEqual(ready, 0)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(ready, 1)
    coordinator.stop()
    coordinator.install(view)
    coordinator.capture(window)
    coordinator.stop()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(ready, 1, "A dismissed modal must not steal focus from its parent")
  }

  @MainActor func testDialogRendersInsideExistingWindowAtNormalAndCompactWidths() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let windowsBefore = Set(NSApp.windows.map(\.windowNumber))
    let request = ArchiveDeletionRequest(kind: .project, taskIDs: ["one", "two"])
    let host = NSHostingView(rootView: Color.gray.overlay(ArchiveDeletionDialog(store: store, request: request)))
    window.contentView = host
    for size in [NSSize(width: 960, height: 600), NSSize(width: 400, height: 300)] {
      window.setContentSize(size); host.frame.size = size
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      XCTAssertNil(window.attachedSheet)
      XCTAssertEqual(Set(NSApp.windows.map(\.windowNumber)), windowsBefore)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(data.count, 5000)
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("archive-dialog-\(Int(size.width)).png"))
      }
    }
  }
}
