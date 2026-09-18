import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class MemoryListInteractionTests: XCTestCase {
  func testNativeSortAndDeletionMenusKeepScopeAndRestoreFocusAfterCancel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMemories()
    XCTAssertTrue(store.addMemory("Alpha"))
    XCTAssertTrue(store.addMemory("Beta"))
    store.openSettings(.memories)
    let (window, host) = makeHost(store)
    defer { window.close() }
    try await settle(host)
    func menu(_ label: String) throws -> SettingsMenuControl {
      try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == label })
    }
    let sort = try menu("记忆排序")
    XCTAssertEqual(sort.imagePosition, .imageOnly)
    XCTAssertFalse(sort.isBordered)
    XCTAssertEqual(sort.menu?.items.filter { $0.state == .on }.map(\.title), ["最新优先"])
    sort.selectItem(withTitle: "最早优先")
    sort.sendAction(sort.action, to: sort.target)
    try await settle(host)
    XCTAssertEqual(sort.menu?.items.filter { $0.state == .on }.map(\.title), ["最早优先"])
    let row = try menu("记忆选项：Alpha")
    row.selectItem(at: 1)
    row.sendAction(row.action, to: row.target)
    try await settle(host)
    XCTAssertEqual(store.memoryDeletion?.items.map(\.text), ["Alpha"])
    XCTAssertFalse(row.isEnabled)
    store.dismissMemoryDeletion()
    try await settle(host)
    XCTAssertTrue(window.firstResponder === row)
    let all = try menu("记忆更多选项")
    all.selectItem(at: 1)
    all.sendAction(all.action, to: all.target)
    try await settle(host)
    XCTAssertEqual(Set(store.memoryDeletion?.items.map(\.text) ?? []), ["Alpha", "Beta"])
    store.dismissMemoryDeletion()
    try await settle(host)
    XCTAssertTrue(window.firstResponder === all)
    XCTAssertEqual(sort.menu?.items.filter { $0.state == .on }.map(\.title), ["最早优先"])
  }

  func testLoadFailureDisablesDeletionAndRepairPreservesDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try MemoryStorage.save(.init(items: [.init(text: "retained")]), root: root)
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMemories()
    store.memoryDraft = "unsaved draft"
    store.openSettings(.memories)
    let (window, host) = makeHost(store)
    defer { window.close() }
    try await settle(host)
    try Data("broken".utf8).write(to: root.appendingPathComponent("memories.json"))
    await store.loadMemories()
    try await settle(host)
    let all = try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == "记忆更多选项" })
    XCTAssertFalse(all.isEnabled)
    XCTAssertFalse(controls(host).contains { $0.accessibilityLabel() == "记忆选项：retained" })
    all.selectItem(at: 1)
    all.sendAction(all.action, to: all.target)
    XCTAssertNil(store.memoryDeletion)
    try MemoryStorage.save(.init(items: [.init(text: "repaired")]), root: root)
    await store.loadMemories()
    try await settle(host)
    XCTAssertTrue(all.isEnabled)
    XCTAssertTrue(controls(host).contains { $0.accessibilityLabel() == "记忆选项：repaired" })
    XCTAssertEqual(store.memoryDraft, "unsaved draft")
  }

  private func makeHost(_ store: WorkspaceStore) -> (NSWindow, NSHostingView<MemoryListFixture>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: MemoryListFixture(store: store))
    window.contentView = host
    return (window, host)
  }
  private func settle(_ host: NSView) async throws {
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
  }
  private func controls(_ view: NSView) -> [SettingsMenuControl] {
    (view as? SettingsMenuControl).map { [$0] } ?? view.subviews.flatMap(controls)
  }
}

private struct MemoryListFixture: View {
  let store: WorkspaceStore
  var body: some View { MemorySettingsView(store: store).disabled(store.memoryDeletion != nil) }
}
