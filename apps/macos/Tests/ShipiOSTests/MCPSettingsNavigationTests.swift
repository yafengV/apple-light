import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class MCPSettingsNavigationTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, MCPServerConfiguration) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-navigation-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMCPServers()
    var server = MCPServerConfiguration()
    server.name = "local-navigation"; server.command = "/usr/bin/true"
    XCTAssertTrue(store.saveMCPServer(server))
    store.showProjects(); store.openSettings(.mcpServers)
    store.openMCPServerEditor(server.id)
    addTeardownBlock {
      await store.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return (store, server)
  }

  func testPageChangeRequiresDecisionAndCancelPreservesDraftWithoutWriting() async throws {
    let (store, original) = try await fixture()
    store.mcpServerEditor?.command = "/usr/bin/false"
    let draft = store.mcpServerEditor
    store.requestSettingsPage(.general)
    XCTAssertEqual(store.settingsPage, .plugins)
    XCTAssertEqual(store.pendingSettingsNavigation, .page(.general))
    XCTAssertEqual(store.mcpServerEditor, draft)
    store.cancelDiscardSettingsChanges()
    XCTAssertEqual(store.mcpServerEditor, draft)
    XCTAssertEqual(store.mcpServers, [original])
    XCTAssertEqual(try MCPServerStorage.load(root: store.dataRoot), [original])
    store.requestSettingsPage(.general)
    store.confirmDiscardSettingsChanges()
    XCTAssertEqual(store.settingsPage, .general)
    XCTAssertNil(store.mcpServerEditor)
    XCTAssertNil(store.pendingSettingsNavigation)
    XCTAssertEqual(try MCPServerStorage.load(root: store.dataRoot), [original])
  }

  func testBackProtectsInvalidDraftAndDiscardReturnsToMCPOverview() async throws {
    let (store, original) = try await fixture()
    store.mcpServerEditor?.command = ""
    let draft = store.mcpServerEditor
    XCTAssertTrue(store.hasUnsavedSettingsEdits, "Invalid edits still need navigation protection")
    store.closeSettings()
    XCTAssertNotNil(store.pendingSettingsNavigation)
    XCTAssertEqual(store.mcpServerEditor, draft)
    store.cancelDiscardSettingsChanges()
    XCTAssertEqual(store.mcpServerEditor, draft)
    store.closeSettings(); store.confirmDiscardSettingsChanges()
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .plugins)
    XCTAssertNil(store.mcpServerEditor)
    XCTAssertEqual(store.mcpServers, [original])
    store.closeSettings()
    XCTAssertEqual(store.destination, .projects)
  }

  func testSamePageSearchCannotSilentlyDiscardEditor() async throws {
    let (store, original) = try await fixture()
    store.mcpServerEditor?.command = "/usr/bin/false"
    let draft = store.mcpServerEditor
    let result = SettingsSearchResult(page: .plugins, field: .mcpImport)
    store.revealSetting(result)
    XCTAssertEqual(store.pendingSettingsNavigation, .reveal(result))
    XCTAssertEqual(store.mcpServerEditor, draft)
    XCTAssertNil(store.settingsSearchRequest)
    store.cancelDiscardSettingsChanges()
    XCTAssertEqual(store.mcpServerEditor, draft)
    store.revealSetting(result); store.confirmDiscardSettingsChanges()
    XCTAssertNil(store.mcpServerEditor)
    XCTAssertEqual(store.settingsSearchRequest?.result, result)
    XCTAssertEqual(try MCPServerStorage.load(root: store.dataRoot), [original])
  }

  func testReopeningSettingsKeepsEditorAndSavingClearsNavigationProtection() async throws {
    let (store, _) = try await fixture()
    store.mcpServerEditor?.command = "/usr/bin/false"
    let draft = try XCTUnwrap(store.mcpServerEditor)
    store.openSettings()
    XCTAssertEqual(store.mcpServerEditor, draft)
    store.openSettings(.plugins)
    XCTAssertEqual(store.mcpServerEditor, draft)
    XCTAssertTrue(store.saveMCPServer(draft))
    XCTAssertNil(store.mcpServerEditor)
    XCTAssertFalse(store.hasUnsavedSettingsEdits)
    store.requestSettingsPage(.general)
    XCTAssertEqual(store.settingsPage, .general)
    XCTAssertNil(store.pendingSettingsNavigation)
    XCTAssertEqual(try MCPServerStorage.load(root: store.dataRoot), [draft])
  }

  func testRenderedEditorAndNavigationShareTheSameUnsavedDraft() async throws {
    _ = NSApplication.shared
    let (store, original) = try await fixture()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 720),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PluginSettingsView(store: store))
    window.contentView = host; host.frame.size = .init(width: 820, height: 720)
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func settle() async throws {
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(120))
      host.layoutSubtreeIfNeeded()
    }
    try await settle()
    let command = try XCTUnwrap(fields(host).first { $0.isEditable && $0.stringValue == original.command })
    store.mcpServerEditor?.command = "/usr/bin/false"
    try await settle()
    XCTAssertEqual(command.stringValue, "/usr/bin/false")
    store.requestSettingsPage(.general); store.cancelDiscardSettingsChanges()
    try await settle()
    XCTAssertEqual(command.stringValue, "/usr/bin/false")
    XCTAssertTrue(fields(host).contains { $0 === command }, "Cancel must retain the editor")
    XCTAssertTrue(store.hasUnsavedSettingsEdits)
    XCTAssertEqual(try MCPServerStorage.load(root: store.dataRoot), [original])
    XCTAssertFalse(window.isVisible)
  }
}
