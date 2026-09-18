import XCTest
import Observation

@testable import ShipiOS

final class GeneralSettingsParityTests: XCTestCase {
  @MainActor func testMenuBarSystemEchoDoesNotPublishOrPersistUnchangedValue() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    // The system can echo the initial value before asynchronous restoration ends.
    store.showInMenuBar = store.showInMenuBar
    XCTAssertNil(store.generalSettingsError)
    store.libraryLoaded = true
    withObservationTracking {
      _ = store.library
    } onChange: {
      XCTFail("An unchanged system echo must not invalidate the scene graph")
    }
    for _ in 0..<20 { store.showInMenuBar = store.showInMenuBar }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace.json").path))
    XCTAssertNil(store.generalSettingsError)
  }

  @MainActor func testMenuBarSystemEchoAfterRealChangeDoesNotRewriteWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.showInMenuBar = false
    let file = root.appendingPathComponent("workspace.json")
    let before = try Data(contentsOf: file)
    let timestamp = Date(timeIntervalSince1970: 123)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    withObservationTracking { _ = store.library } onChange: {
      XCTFail("Repeated MenuBarExtra callbacks must not publish another library")
    }
    for _ in 0..<20 { store.showInMenuBar = false }
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, timestamp)
  }

  @MainActor func testPluginMasterSwitchPersistsAndRemovesComposerAndRequestCapabilities() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.pluginPreferences = PluginPreferences(installed: [
      PluginInstallation(
        id: "fixture", name: "Fixture", summary: "", version: "1", enabled: true,
        installedAt: Date(timeIntervalSince1970: 1), components: PluginComponents(skills: 1))
    ])
    store.pluginSkills = [
      PluginSkillReference(
        pluginID: "fixture", pluginName: "Fixture", skillID: "review", title: "Review",
        fileURL: root.appendingPathComponent("SKILL.md"), mention: "review")
    ]

    XCTAssertEqual(store.composerPlugins.map(\.id), ["fixture"])
    XCTAssertEqual(store.composerSkills.map(\.id), ["fixture/review"])
    XCTAssertEqual(store.activePluginPreferences.installed.map(\.id), ["fixture"])

    store.pluginsEnabled = false

    XCTAssertTrue(store.composerPlugins.isEmpty)
    XCTAssertTrue(store.composerSkills.isEmpty)
    XCTAssertTrue(store.activePluginPreferences.installed.isEmpty)
    XCTAssertFalse(store.generalSettingsError != nil, store.generalSettingsError ?? "")
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertFalse(restored.pluginsEnabled)
  }

  @MainActor func testContextIndicatorUsesLatestAuthoritativeInputUsageAndPersists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let first = chatRun("first", input: 120, output: 20, createdAt: 1)
    let latest = chatRun("latest", input: 345, output: 30, createdAt: 3)
    store.library.chatRuns = [first, latest]
    store.library.attach(first, to: nil, note: "first")
    let taskID = try XCTUnwrap(store.library.task(containing: first.id)?.id)
    store.library.attach(latest, to: taskID, note: "latest")
    store.runs = [first, latest]
    store.selection = latest.id

    XCTAssertEqual(store.contextInputTokens(taskID: taskID), 345)
    store.showContextUsageIndicator = true
    store.showBottomPanelControl = false
    XCTAssertNil(store.generalSettingsError)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertTrue(restored.showContextUsageIndicator)
    XCTAssertFalse(restored.showBottomPanelControl)
  }

  func testLegacyWorkspaceDefaultsPluginsOnAndContextIndicatorOff() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(legacy.pluginsEnabled)
    XCTAssertTrue(legacy.showInMenuBar)
    XCTAssertTrue(legacy.showEducationalTips)
    XCTAssertTrue(legacy.dismissedEducationalTipIDs.isEmpty)
    XCTAssertFalse(legacy.showContextUsageIndicator)
    XCTAssertTrue(legacy.showBottomPanelControl)
    XCTAssertFalse(legacy.composerPlainTextMode)
    XCTAssertEqual(legacy.webLinkTarget, .inAppBrowser)
    XCTAssertNil(legacy.projectlessWorkspaceRoot)
    XCTAssertTrue(legacy.projectlessTaskDirectories.isEmpty)
    XCTAssertFalse(legacy.popoutWindowProjectlessDefault)
    XCTAssertEqual(legacy.gitPreferences.reviewDelivery, .inline)
  }

  @MainActor func testMenuBarPreferenceDefaultsOnAndPersists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true

    XCTAssertTrue(store.showInMenuBar)
    store.showInMenuBar = false

    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertFalse(restored.showInMenuBar)
  }

  @MainActor func testLastWindowCloseKeepsMenuBarAppAliveOnlyWhenEnabled() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let delegate = AppDelegate()
    delegate.store = store

    XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    store.showInMenuBar = false
    XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
  }

  @MainActor func testEducationalTipsPersistDismissalAndRemainSeparateFromSuggestions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true

    XCTAssertEqual(store.educationalTip(taskID: nil), .planMode)
    store.personalization.showSuggestedPrompts = false
    XCTAssertEqual(store.educationalTip(taskID: nil), .planMode)

    store.dismissEducationalTip(ComposerEducationalTip.planMode.id)
    XCTAssertEqual(store.educationalTip(taskID: nil), .skills)
    store.showEducationalTips = false
    XCTAssertNil(store.educationalTip(taskID: nil))

    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertFalse(restored.showEducationalTips)
    XCTAssertEqual(restored.dismissedEducationalTipIDs, [ComposerEducationalTip.planMode.id])
  }

  @MainActor func testEducationalTipActionsAppendDraftAndUseRealDestinations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.draft = "保留现有内容"

    XCTAssertFalse(store.performEducationalTip(.planMode, taskID: nil))
    XCTAssertEqual(store.draft, "保留现有内容 请先为这个任务制定计划，再开始修改。")
    XCTAssertTrue(store.library.dismissedEducationalTipIDs.contains("plan-mode"))

    XCTAssertTrue(store.performEducationalTip(.skills, taskID: nil))
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .plugins)
    XCTAssertEqual(store.pluginSettingsSection, .skills)
  }

  @MainActor func testTaskWindowEducationalTipKeepsDraftScopedToTask() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.tasks = [
      WorkspaceTask(id: "first", project: "", title: "First", runIDs: []),
      WorkspaceTask(id: "second", project: "", title: "Second", runIDs: []),
    ]
    store.setTaskWindowDraft("原草稿", taskID: "first")
    store.setTaskWindowDraft("其他草稿", taskID: "second")

    XCTAssertFalse(store.performEducationalTip(.planMode, taskID: "first"))
    XCTAssertEqual(store.taskWindowDraft("first"), "原草稿 请先为这个任务制定计划，再开始修改。")
    XCTAssertEqual(store.taskWindowDraft("second"), "其他草稿")
  }

  @MainActor func testReviewDeliveryPersistsAndLegacyGitPreferencesDefaultInline() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    var preferences = store.library.gitPreferences
    preferences.reviewDelivery = .detached
    store.saveGitPreferences(preferences)

    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.gitPreferences.reviewDelivery, .detached)

    let legacy = try JSONDecoder().decode(
      GitPreferences.self,
      from: Data(#"{"branchPrefix":"legacy/","defaultReviewScope":"staged","readOnlyReview":true}"#.utf8))
    XCTAssertEqual(legacy.reviewDelivery, .inline)
    XCTAssertEqual(legacy.branchPrefix, "legacy/")
    XCTAssertEqual(legacy.defaultReviewScope, .staged)
    XCTAssertTrue(legacy.readOnlyReview)
  }

  @MainActor func testPlainTextComposerPreferencePersists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true

    store.composerPlainTextMode = true

    XCTAssertTrue(store.composerPlainTextMode)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertTrue(restored.composerPlainTextMode)
  }

  @MainActor func testLinkTargetAndProjectlessRootPersistWithoutUsingPersonalCodexState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = root.appendingPathComponent("Standalone Output", isDirectory: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true

    store.webLinkTarget = .externalBrowser
    store.setProjectlessWorkspaceRoot(custom)

    XCTAssertEqual(store.webLinkTarget, .externalBrowser)
    XCTAssertEqual(store.projectlessWorkspaceRoot, custom)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: custom.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.webLinkTarget, .externalBrowser)
    XCTAssertEqual(restored.projectlessWorkspaceRoot, custom.path)
  }

  @MainActor func testPopoutTaskDefaultSelectsScopeAndPersists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.project = root.appendingPathComponent("Project", isDirectory: true)

    let projectDraft = try XCTUnwrap(store.createPopoutTask())
    XCTAssertEqual(projectDraft.project, store.currentProjectKey)
    XCTAssertTrue(projectDraft.isPopoutDraft)

    store.popoutWindowProjectlessDefault = true
    let projectlessDraft = try XCTUnwrap(store.createPopoutTask())
    XCTAssertEqual(projectlessDraft.project, "")
    XCTAssertTrue(projectlessDraft.isPopoutDraft)

    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertTrue(restored.popoutWindowProjectlessDefault)
    XCTAssertEqual(Set(restored.tasks.filter(\.isPopoutDraft).map(\.id)),
      Set([projectDraft.id, projectlessDraft.id]))
  }

  @MainActor func testPopoutDraftStaysHiddenPromotesOnFirstRunAndEmptyDraftCanBeDiscarded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.popoutWindowProjectlessDefault = true
    let draft = try XCTUnwrap(store.createPopoutTask())

    XCTAssertTrue(store.library.visible(project: "", query: "", archived: false).isEmpty)
    XCTAssertFalse(store.library.sidebarItems(in: SidebarLayout.projectless).contains(.task(draft.id)))
    XCTAssertTrue(TaskSearchRequest(
      query: "", tasks: store.library.tasks, names: [:], notes: [:], branches: [:], runs: []
    ).search().isEmpty)

    let run = chatRun("popout-run", input: 2, output: 1, createdAt: 1)
    store.library.attach(run, to: draft.id, note: "first popout prompt")
    let promoted = try XCTUnwrap(store.library.tasks.first { $0.id == draft.id })
    XCTAssertFalse(promoted.isPopoutDraft)
    XCTAssertEqual(promoted.title, "first popout prompt")
    XCTAssertEqual(promoted.runIDs, [run.id])
    XCTAssertEqual(store.library.visible(project: "", query: "", archived: false).map(\.id), [draft.id])

    let empty = try XCTUnwrap(store.createPopoutTask())
    store.setTaskWindowDraft("temporary", taskID: empty.id)
    store.discardPopoutTaskIfEmpty(empty.id)
    XCTAssertFalse(store.library.tasks.contains { $0.id == empty.id })
    XCTAssertNil(store.library.drafts[empty.id])
  }

  @MainActor func testProjectlessTaskDirectoriesAreStableAndResolveRelativeOutputLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true

    let first = try store.projectlessWorkspace(taskID: "task-one", create: true)
    let same = try store.projectlessWorkspace(taskID: "task-one", create: false)
    let other = try store.projectlessWorkspace(taskID: "task-two", create: true)
    XCTAssertEqual(first, same)
    XCTAssertNotEqual(first, other)
    XCTAssertTrue(first.path.hasPrefix(root.appendingPathComponent("Projectless").path + "/"))

    let run = AgentRun(
      id: "run", kind: "chat", project: "", status: "succeeded", createdAt: 1,
      updatedAt: 2,
      request: .object([
        "model": .string("fixture"), "workspace": .string(first.path),
      ]),
      result: .object(["response": .string("done")]))
    store.library.chatRuns = [run]
    store.library.attach(run, to: nil, note: "create a file")
    let taskID = try XCTUnwrap(store.library.task(containing: run.id)?.id)
    store.library.projectlessTaskDirectories[taskID] = first.path
    XCTAssertEqual(store.workspaceRoot(for: run), first)
    XCTAssertEqual(
      try MessageLink.target(XCTUnwrap(MessageLink.url("result.md:4")), root: first),
      .file(path: "result.md", line: 4))
  }

  @MainActor func testInAppWebLinkOpensForItsTaskAsAContentTab() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let run = chatRun("link-run", input: 1, output: 1, createdAt: 1)
    store.library.chatRuns = [run]
    store.library.attach(run, to: nil, note: "link")
    store.runs = [run]

    let url = try XCTUnwrap(URL(string: "https://example.invalid/from-message"))
    await store.openWebLinkInApp(url, ownerRunID: run.id)

    XCTAssertEqual(store.selectedTask?.id, run.id)
    XCTAssertEqual(store.workspace.browser.selected?.address, url.absoluteString)
    XCTAssertNil(store.activeWorkspaceContentTab)
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.owner, run.id)
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.browserID, store.workspace.browser.selected?.id)
    XCTAssertTrue(store.showingInspector)
    store.workspace.browser.shutdown()
  }

  private func chatRun(_ id: String, input: Int, output: Int, createdAt: Double) -> AgentRun {
    AgentRun(
      id: id, kind: "chat", project: "", status: "succeeded", createdAt: createdAt,
      updatedAt: createdAt + 1, request: .object(["model": .string("fixture")]),
      result: .object([
        "response": .string("done"),
        "usage": ModelTokenUsage(inputTokens: input, outputTokens: output).jsonValue,
      ]))
  }
}
