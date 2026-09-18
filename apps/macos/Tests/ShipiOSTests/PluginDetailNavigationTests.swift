import XCTest
@testable import ShipiOS

final class PluginDetailNavigationTests: XCTestCase {
  private var plugin: PluginInstallation {
    .init(id: "example", name: "Example", summary: "Example plugin", version: "1", enabled: true,
      installedAt: Date(), components: .init(skills: 1, mcpServers: 1))
  }

  @MainActor func testDirectoryDetailBackAndForwardKeepTaskHistoryAndListMounted() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.restoringLibrary = false
    store.pluginPreferences = .init(installed: [plugin])
    store.library.drafts["new:none"] = "保留"
    store.recordNavigation()
    let taskHistory = store.navigationBack.count
    store.showPlugins()
    store.openPluginDetail(plugin.id)
    XCTAssertEqual(store.destination, .pluginDetail)
    XCTAssertEqual(store.currentPluginDetail?.id, plugin.id)
    XCTAssertTrue(store.retainsPluginsPage)
    XCTAssertFalse(store.canSend)
    await store.navigate(back: true)
    XCTAssertEqual(store.destination, .plugins)
    XCTAssertTrue(store.commandEnabled("forward"))
    await store.navigate(back: false)
    XCTAssertEqual(store.destination, .pluginDetail)
    XCTAssertEqual(store.navigationBack.count, taskHistory)
    XCTAssertEqual(store.library.drafts["new:none"], "保留")
    store.closePluginDetail()
    store.showProjects()
    XCTAssertFalse(store.canGoForwardToPluginDetail)
    XCTAssertNil(store.pluginDetailRoute)
  }

  @MainActor func testSettingsDetailReturnsToExactTabFilterAndOriginalPage() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.pluginPreferences = .init(installed: [plugin])
    store.showProjects()
    store.openSettings(.skills)
    store.pluginSettingsQuery = "example"
    store.openPluginDetail(plugin.id)
    XCTAssertTrue(store.retainsSettingsPage)
    XCTAssertTrue(store.retainsProjectsPage)
    // Opening global settings from a detail page must return to that detail first.
    store.openSettings(.appearance)
    XCTAssertEqual(store.settingsReturnDestination, .pluginDetail)
    store.closeSettings()
    XCTAssertEqual(store.destination, .pluginDetail)
    store.closePluginDetail()
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .plugins)
    XCTAssertEqual(store.pluginSettingsSection, .skills)
    XCTAssertEqual(store.pluginSettingsQuery, "example")
    XCTAssertEqual(store.settingsReturnDestination, .projects)
    store.closeSettings()
    XCTAssertEqual(store.destination, .projects)
  }

  @MainActor func testInvalidAndRemovedPluginsCannotRestoreEditableStaleDetails() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.showPlugins()
    store.openPluginDetail("missing")
    XCTAssertEqual(store.destination, .plugins)
    XCTAssertNil(store.pluginDetailRoute)
    store.pluginPreferences = .init(installed: [plugin])
    store.openPluginDetail(plugin.id)
    store.pluginPreferences = .init()
    XCTAssertNil(store.currentPluginDetail)
    store.closePluginDetail()
    XCTAssertEqual(store.destination, .plugins)
    XCTAssertFalse(store.canGoForwardToPluginDetail)
    store.goForwardToPluginDetail()
    XCTAssertEqual(store.destination, .plugins)
  }

  @MainActor func testOpeningDifferentSettingsPageInvalidatesDetailForwardRoute() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.pluginPreferences = .init(installed: [plugin])
    store.openSettings(.plugins)
    store.openPluginDetail(plugin.id)
    store.closePluginDetail()
    XCTAssertTrue(store.canGoForwardToPluginDetail)
    store.settingsPage = .general
    XCTAssertFalse(store.canGoForwardToPluginDetail)
    XCTAssertNil(store.pluginDetailForwardRoute)
  }
}
