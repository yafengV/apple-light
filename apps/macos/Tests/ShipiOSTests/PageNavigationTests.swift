import XCTest

@testable import ShipiOS

final class PageNavigationTests: XCTestCase {
  @MainActor func testCodingSettingsNormalizePreferencesAndOpenReview() {
    let store = WorkspaceStore()
    var preferences = store.library.gitPreferences
    preferences.branchPrefix = " /feature "
    preferences.defaultReviewScope = .branch
    preferences.readOnlyReview = true
    store.saveGitPreferences(preferences)
    XCTAssertEqual(store.library.gitPreferences.branchPrefix, "feature/")
    XCTAssertEqual(store.library.gitPreferences.defaultReviewScope, .branch)
    XCTAssertTrue(store.library.gitPreferences.readOnlyReview)

    store.project = URL(fileURLWithPath: "/project")
    store.openSettings(.codeReview)
    store.openReviewFromSettings()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.workspace.reviewScope, .branch)
    XCTAssertNotNil(store.activeWorkspaceContentTab)
  }

  @MainActor func testRestorationBlocksMenuCommandsUntilConfigurationIsReady() {
    let store = WorkspaceStore()
    store.restoringLibrary = true
    for command in DesktopCommand.all {
      XCTAssertFalse(store.commandEnabled(command.id), command.id)
      store.executeCommand(command.id)
    }
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertNil(store.presentedOverlay)
    XCTAssertFalse(store.showingModelPicker)
    XCTAssertFalse(store.showingInspector)
    store.restoringLibrary = false
    XCTAssertTrue(store.commandEnabled("settings"))
    store.executeCommand("model")
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .model)
  }

  @MainActor func testGlobalOverlaysKeepEverySettingsCategoryAndReturnDestination() {
    let store = WorkspaceStore()
    for page in SettingsPage.allCases {
      store.showProjects()
      store.openSettings(page)
      for command in ["palette", "palette-alternate", "search"] {
        store.executeCommand(command)
        XCTAssertEqual(store.presentedOverlay, command == "search" ? .taskSearch : .commands)
        XCTAssertEqual(store.destination, .settings)
        XCTAssertEqual(store.settingsPage, page.navigationPage)
        store.presentedOverlay = nil
        XCTAssertEqual(store.destination, .settings)
      }
      store.closeSettings()
      XCTAssertEqual(store.destination, .projects)
    }
  }

  @MainActor func testOnlyOneGlobalOverlayAndOldDismissalDoesNotClearReplacement() {
    let store = WorkspaceStore()
    store.showingCommands = true
    store.showingSearch = true
    store.showingCommands = false
    XCTAssertTrue(store.showingSearch)
    XCTAssertFalse(store.showingCommands)
    store.showingFileSearch = true
    store.showingSearch = false
    XCTAssertEqual(store.presentedOverlay, .fileSearch)
    store.openSettings(.general)
    XCTAssertNil(store.presentedOverlay)
  }

  @MainActor func testDisabledCommandsCannotMutateHiddenWorkspace() {
    let store = WorkspaceStore()
    store.showingInspector = true
    store.showingTerminal = true
    store.draft = "unsent draft"
    store.openSettings()
    for command in ["fork", "archive", "rename", "pin", "unread", "files", "terminal", "review"] {
      store.executeCommand(command)
    }
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.draft, "unsent draft")
    XCTAssertNil(store.presentedOverlay)
    XCTAssertTrue(store.showingInspector)
    XCTAssertTrue(store.showingTerminal)
  }

  @MainActor func testEverySettingsCategoryPreservesActiveWorkspace() async {
    let store = WorkspaceStore()
    store.connected = true
    store.project = URL(fileURLWithPath: "/project")
    let run = AgentRun(
      id: "active", kind: "chat", project: "/project", status: "running", createdAt: 0,
      updatedAt: 0, request: .null, result: nil)
    store.runs = [run]
    store.library.attach(run, to: nil, note: "request")
    store.selection = run.id
    store.draft = "unsent draft"
    store.showingInspector = true
    store.pane = "review"
    store.showingTerminal = true
    let focus = store.focusComposer
    for page in SettingsPage.allCases {
      store.openSettings(page)
      XCTAssertEqual(store.destination, .settings)
      XCTAssertEqual(store.settingsPage, page.navigationPage)
      XCTAssertEqual(store.activeRun?.id, run.id)
      XCTAssertEqual(store.selection, run.id)
      XCTAssertEqual(store.draft, "unsent draft")
      XCTAssertFalse(store.canSend)
      await store.sendDraft()
      XCTAssertTrue(store.library.queuedMessages.isEmpty)
    }
    await store.navigate(back: true)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.draft, "unsent draft")
    XCTAssertTrue(store.showingInspector)
    XCTAssertTrue(store.showingTerminal)
    XCTAssertEqual(store.pane, "review")
    XCTAssertNotEqual(store.focusComposer, focus)
    XCTAssertTrue(store.canSend)
  }

  @MainActor func testSettingsReentryReturnsToProjectsNotWorkspace() {
    let store = WorkspaceStore()
    store.showProjects()
    store.openSettings(.model)
    store.openSettings(.shortcuts)
    store.openSettings()
    XCTAssertTrue(store.retainsProjectsPage)
    XCTAssertEqual(store.settingsPage, .shortcuts)
    store.closeSettings()
    XCTAssertEqual(store.destination, .projects)
    store.returnToWorkspace()
    XCTAssertFalse(store.retainsProjectsPage)
  }

  @MainActor func testMenuRoutesDismissTransientSearchAndAllowNewTask() {
    let store = WorkspaceStore()
    store.showingCommands = true
    store.showingSearch = true
    store.showingFileSearch = true
    store.executeCommand("settings")
    XCTAssertEqual(store.destination, .settings)
    XCTAssertFalse(store.showingCommands)
    XCTAssertFalse(store.showingSearch)
    XCTAssertFalse(store.showingFileSearch)
    store.newTask()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertNil(store.selection)
    store.executeCommand("projects")
    XCTAssertEqual(store.destination, .projects)
  }
}
