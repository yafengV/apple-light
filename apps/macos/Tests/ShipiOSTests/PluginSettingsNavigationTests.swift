import XCTest
@testable import ShipiOS

final class PluginSettingsNavigationTests: XCTestCase {
  private var plugin: PluginInstallation {
    .init(id: "test", name: "Test", summary: "", version: "1", enabled: false,
      installedAt: Date(), components: .init(skills: 2, mcpServers: 3))
  }

  func testCombinedNavigationKeepsLegacyLinksWithoutDuplicateSidebarEntries() {
    XCTAssertTrue(SettingsNavigation.pages.contains(.plugins))
    XCTAssertFalse(SettingsNavigation.pages.contains(.mcpServers))
    XCTAssertFalse(SettingsNavigation.pages.contains(.skills))
    XCTAssertEqual(SettingsPage.skills.navigationPage, .plugins)
    XCTAssertEqual(SettingsPage.mcpServers.navigationPage, .plugins)
    XCTAssertEqual(SettingsNavigation.results(for: "MCP"), [.plugins])
    XCTAssertEqual(SettingsNavigation.results(for: "Skills"), [.plugins])
    XCTAssertEqual(SettingsSearch.results(for: "已安装技能").compactMap(\.field), [.skillsInstalled])
    XCTAssertEqual(SettingsSearchField.skillsInstalled.page, .plugins)
    XCTAssertEqual(SettingsSearchField.mcpInstalled.page, .plugins)
  }

  func testTabsUseInstalledCountsAndKeepMCPWhenEmptyOrPluginsDisabled() {
    XCTAssertEqual(PluginSettingsSection.visible(in: [], pluginsEnabled: true), [.mcpServers])
    XCTAssertEqual(PluginSettingsSection.visible(in: [plugin], pluginsEnabled: true), [.plugins, .mcpServers, .skills])
    XCTAssertEqual(PluginSettingsSection.visible(in: [plugin], pluginsEnabled: false), [.mcpServers])
    XCTAssertEqual(PluginSettingsSection.plugins.count(in: [plugin]), 1)
    XCTAssertEqual(PluginSettingsSection.skills.count(in: [plugin]), 2)
    XCTAssertEqual(PluginSettingsSection.mcpServers.count(in: [plugin]), 3)
    XCTAssertFalse(SettingsSearch.results(for: "技能", pluginSections: [.mcpServers])
      .contains { $0.field?.pluginSection == .skills })
  }

  @MainActor func testLegacyRoutesSearchAndReturnPreserveDraftWithoutChangingPlugins() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.pluginPreferences = .init(installed: [plugin])
    store.library.drafts["new:none"] = "草稿"
    store.showProjects()
    store.openSettings(.skills)
    XCTAssertEqual(store.settingsPage, .plugins)
    XCTAssertEqual(store.activePluginSettingsSection, .skills)
    store.openSettings(.mcpServers)
    XCTAssertEqual(store.settingsPage, .plugins)
    XCTAssertEqual(store.activePluginSettingsSection, .mcpServers)
    store.pluginSettingsQuery = "之前的筛选"
    store.revealSetting(.init(page: .plugins, field: .skillsInstalled))
    XCTAssertEqual(store.activePluginSettingsSection, .skills)
    XCTAssertEqual(store.pluginSettingsQuery, "")
    XCTAssertEqual(store.settingsSearchRequest?.result.field, .skillsInstalled)
    store.pluginSettingsSection = .mcpServers
    XCTAssertNil(store.settingsSearchRequest)
    store.revealSetting(.init(page: .plugins, field: .pluginsInstalled))
    store.pluginSettingsQuery = "新的筛选"
    XCTAssertNil(store.settingsSearchRequest)
    store.closeSettings()
    XCTAssertEqual(store.destination, .projects)
    XCTAssertEqual(store.library.drafts["new:none"], "草稿")
    XCTAssertFalse(store.pluginPreferences.installed[0].enabled)
  }

  @MainActor func testRemovalAndGlobalDisableCancelStaleSearchTargets() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.pluginPreferences = .init(installed: [plugin])
    let target = SettingsSearchResult(page: .plugins, field: .skillsInstalled)
    store.libraryLoaded = true
    store.revealSetting(target)
    store.pluginPreferences = .init()
    XCTAssertNil(store.settingsSearchRequest)
    XCTAssertEqual(store.activePluginSettingsSection, .mcpServers)
    store.revealSetting(target)
    XCTAssertNil(store.settingsSearchRequest)
    store.pluginPreferences = .init(installed: [plugin])
    store.revealSetting(target)
    store.pluginsEnabled = false
    XCTAssertNil(store.settingsSearchRequest)
    XCTAssertEqual(store.activePluginSettingsSection, .mcpServers)
    store.revealSetting(target)
    XCTAssertNil(store.settingsSearchRequest)
  }
}
