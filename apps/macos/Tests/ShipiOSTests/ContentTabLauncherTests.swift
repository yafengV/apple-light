import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class ContentTabLauncherTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, TaskWindowResources, TaskWindowTabs) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.project = root
    store.library.tasks = [.init(id: "popup", project: root.path, title: "Popup", runIDs: []),
      .init(id: "main", project: root.path, title: "Main", runIDs: [])]
    store.selection = "main"
    store.library.drafts["main"] = "Keep main"
    store.library.drafts["popup"] = "Keep popup"
    let resources = TaskWindowResources()
    resources.prepare("popup", store: store)
    return (store, resources, try XCTUnwrap(resources.tasks["popup"]))
  }
  private func plugin(_ id: String, enabled: Bool = true) -> PluginInstallation {
    .init(id: id, name: "Same display name", summary: "", version: "1", enabled: enabled,
      installedAt: Date(), components: .init())
  }

  func testIndependentLauncherCreatesContentInItsOwnTaskAndPlacement() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    let mainFocus = store.focusComposer
    XCTAssertFalse(store.performContentTabLauncherAction(.browser, in: .right, taskTabs: tabs, openFiles: {}))
    XCTAssertNotNil(tabs.selected(.right)?.browserID)
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    store.library.gitPreferences.defaultReviewScope = .staged
    store.performContentTabLauncherAction(.review, in: .left, taskTabs: tabs, openFiles: {})
    XCTAssertEqual(tabs.selected(.left), .review(owner: "popup"))
    XCTAssertEqual(tabs.panels.workspace.reviewScope, .staged)
    store.performContentTabLauncherAction(.terminal, in: .right, taskTabs: tabs, openFiles: {})
    let session = try XCTUnwrap(tabs.panels.terminal)
    XCTAssertEqual(tabs.selected(.bottom)?.terminalID, session.id)
    XCTAssertTrue(session.view.process.running)
    XCTAssertTrue(store.workspaceTabs.isEmpty)
    XCTAssertEqual(store.selection, "main")
    XCTAssertEqual(store.library.drafts["main"], "Keep main")
    XCTAssertEqual(store.library.drafts["popup"], "Keep popup")
    XCTAssertEqual(store.focusComposer, mainFocus)
  }

  func testReopenAndFileActionsStayInOriginatingWindow() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser(in: .right)
    tabs.close(try XCTUnwrap(tabs.focusedID))
    XCTAssertTrue(tabs.canReopen)
    store.performContentTabLauncherAction(.reopen, in: .left, taskTabs: tabs, openFiles: {})
    XCTAssertNotNil(tabs.selected(.right)?.browserID)
    XCTAssertFalse(tabs.canReopen)
    var openedFiles = 0
    XCTAssertFalse(store.performContentTabLauncherAction(.files, in: .right, taskTabs: tabs,
      openFiles: { openedFiles += 1 }))
    XCTAssertEqual(openedFiles, 1)
    XCTAssertTrue(store.workspaceTabs.isEmpty)
    XCTAssertEqual(store.selection, "main")
  }

  func testTerminalOptionsUsesMainWindowSettingsAndPreservesTaskContent() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser()
    let browser = tabs.browser.session.selected
    XCTAssertTrue(store.performContentTabLauncherAction(.terminalOptions, in: .bottom,
      taskTabs: tabs, openFiles: {}))
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .runtime)
    XCTAssertTrue(tabs.browser.session.selected === browser)
    XCTAssertEqual(store.selection, "main")
    XCTAssertEqual(store.library.drafts["popup"], "Keep popup")
    store.closeSettings()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertTrue(tabs.browser.session.selected === browser)
  }

  func testPluginEntryOpensExactEnabledPluginAndReturnsToCatalog() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    store.pluginPreferences.installed = [plugin("first"), plugin("second")]
    XCTAssertTrue(store.performContentTabLauncherAction(.plugin("second"), in: .right,
      taskTabs: tabs, openFiles: {}))
    XCTAssertEqual(store.destination, .pluginDetail)
    XCTAssertEqual(store.currentPluginDetail?.id, "second")
    XCTAssertEqual(store.selection, "main")
    XCTAssertEqual(store.library.drafts["main"], "Keep main")
    store.closePluginDetail()
    XCTAssertEqual(store.destination, .plugins)
    XCTAssertTrue(store.performContentTabLauncherAction(.automations, in: .left,
      taskTabs: tabs, openFiles: {}))
    XCTAssertEqual(store.destination, .automations)
    XCTAssertTrue(store.performContentTabLauncherAction(.plugins, in: .left,
      taskTabs: tabs, openFiles: {}))
    XCTAssertEqual(store.destination, .plugins)
  }

  func testStalePluginEntryDoesNotNavigateOrActivateMainWindow() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    store.pluginPreferences.installed = [plugin("disabled", enabled: false)]
    for id in ["disabled", "removed"] {
      XCTAssertFalse(store.performContentTabLauncherAction(.plugin(id), in: .left,
        taskTabs: tabs, openFiles: {}))
      XCTAssertEqual(store.destination, .workspace)
      XCTAssertNil(store.pluginDetailRoute)
    }
  }

  func testProjectlessTaskCannotUseMainProjectsToolsOrBottomBrowser() throws {
    let (store, resources, _) = try fixture()
    defer { resources.shutdown() }
    store.library.tasks.append(.init(id: "projectless", project: "", title: "No project", runIDs: []))
    resources.prepare("projectless", store: store)
    let tabs = try XCTUnwrap(resources.tasks["projectless"])
    XCTAssertNil(tabs.panels.workspace.root)
    var files = 0
    for action: ContentTabLauncherAction in [.terminal, .review, .files] {
      XCTAssertFalse(store.performContentTabLauncherAction(action, in: .left,
        taskTabs: tabs, openFiles: { files += 1 }))
    }
    store.performContentTabLauncherAction(.browser, in: .bottom, taskTabs: tabs, openFiles: {})
    XCTAssertTrue(tabs.tabs.isEmpty)
    XCTAssertEqual(files, 0)
    store.performContentTabLauncherAction(.browser, in: .left, taskTabs: tabs, openFiles: {})
    XCTAssertEqual(tabs.tabs.count, 1)
  }

  func testMainLauncherStillUsesMainContentAndDoesNotRaiseAnotherWindow() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown(); store.workspace.browser.shutdown(); store.workspace.terminals.shutdown() }
    XCTAssertFalse(store.performContentTabLauncherAction(.browser, in: .right, openFiles: {}))
    XCTAssertNotNil(store.activeRightWorkspaceContentTab?.browserID)
    XCTAssertTrue(tabs.tabs.isEmpty)
    XCTAssertFalse(store.performContentTabLauncherAction(.terminal, in: .left, openFiles: {}))
    XCTAssertNotNil(store.activeBottomWorkspaceContentTab?.terminalID)
    store.pluginPreferences.installed = [plugin("main-plugin")]
    XCTAssertFalse(store.performContentTabLauncherAction(.plugin("main-plugin"), in: .left, openFiles: {}))
    XCTAssertEqual(store.currentPluginDetail?.id, "main-plugin")
  }
}
