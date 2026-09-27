import XCTest

@testable import ShipiOS

final class MCPCommandTests: XCTestCase {
  @MainActor func testSlashMCPShowsConnectionStatusInTheMainSettingsPage() {
    let store = WorkspaceStore()
    store.library.tasks = [.init(id: "task", project: "", title: "Current", runIDs: [])]
    store.selection = "task"
    store.draft = "/mcp"

    var selection = ComposerCommandSelection()
    selection.update(draft: "/mc", enabled: store.enabledComposerCommands)
    XCTAssertEqual(selection.matches, [.mcp])
    XCTAssertEqual(ComposerCommand.mcp.actionID, "mcp-status")
    XCTAssertEqual(DesktopCommand.all.first(where: { $0.id == "mcp-status" })?.group, .configure)

    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .plugins)
    XCTAssertEqual(store.activePluginSettingsSection, .mcpServers)
    XCTAssertEqual(store.selection, "task")
    XCTAssertEqual(store.draft, "")
    store.closeSettings()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selection, "task")
  }

  @MainActor func testMCPStatusCommandOpensTheSameSection() {
    let store = WorkspaceStore()
    store.executeCommand("mcp-status")
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.activePluginSettingsSection, .mcpServers)
  }
}
