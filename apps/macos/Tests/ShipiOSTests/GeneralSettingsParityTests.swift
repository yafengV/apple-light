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
    XCTAssertFalse(legacy.confettiEnabled)
    XCTAssertFalse(legacy.audioVisualizerEnabled)
    XCTAssertTrue(legacy.dismissedEducationalTipIDs.isEmpty)
    XCTAssertFalse(legacy.showContextUsageIndicator)
    XCTAssertTrue(legacy.showBottomPanelControl)
    XCTAssertFalse(legacy.composerPlainTextMode)
    XCTAssertEqual(legacy.webLinkTarget, .inAppBrowser)
    XCTAssertNil(legacy.projectlessWorkspaceRoot)
    XCTAssertTrue(legacy.projectlessTaskDirectories.isEmpty)
    XCTAssertFalse(legacy.popoutWindowProjectlessDefault)
    XCTAssertNil(legacy.popoutHomeRuntimePreferences)
    XCTAssertTrue(legacy.taskRuntimePreferences.isEmpty)
    XCTAssertEqual(legacy.gitPreferences.reviewDelivery, .inline)
  }

  @MainActor func testAudioVisualizerPreferencePersistsInWorkspaceLibrary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.audioVisualizerEnabled = true
    XCTAssertTrue(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .audioVisualizerEnabled)
    store.audioVisualizerEnabled = false
    XCTAssertFalse(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .audioVisualizerEnabled)
  }

  @MainActor func testConfettiPreferenceControlsRealBurstAndRespectsReducedMotion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true

    XCTAssertFalse(store.fireConfetti())
    XCTAssertNil(store.confettiBurst)
    store.confettiEnabled = true
    XCTAssertTrue(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).confettiEnabled)
    var appearance = store.appearance
    appearance.reduceMotion = .off
    store.library.appearance = appearance
    XCTAssertTrue(store.fireConfetti())
    XCTAssertNotNil(store.confettiBurst)
    let first = store.confettiBurst
    XCTAssertTrue(store.fireConfetti())
    XCTAssertNotEqual(first, store.confettiBurst)

    appearance.reduceMotion = .on
    store.library.appearance = appearance
    store.confettiBurst = nil
    XCTAssertFalse(store.fireConfetti())
    XCTAssertNil(store.confettiBurst)
    store.confettiEnabled = false
    XCTAssertFalse(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).confettiEnabled)
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
    let scopedDraft = try XCTUnwrap(store.createPopoutTask(projectless: false))
    XCTAssertEqual(scopedDraft.project, store.currentProjectKey)
    XCTAssertTrue(store.popoutWindowProjectlessDefault,
      "Choosing a scope in the popout must not rewrite the default")

    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertTrue(restored.popoutWindowProjectlessDefault)
    XCTAssertEqual(Set(restored.tasks.filter(\.isPopoutDraft).map(\.id)),
      Set([projectDraft.id, projectlessDraft.id, scopedDraft.id]))
  }

  @MainActor func testPopoutHomeSubmissionPreparesOneScopedDraftWithoutChangingMainDraft() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.project = root.appendingPathComponent("Project", isDirectory: true)
    store.draft = "Main draft"
    XCTAssertNil(store.preparePopoutTask(prompt: "  ", projectless: true))
    XCTAssertTrue(store.library.tasks.isEmpty)
    let task = try XCTUnwrap(store.preparePopoutTask(prompt: "Separate prompt", projectless: true))
    XCTAssertEqual(task.project, "")
    XCTAssertEqual(store.taskWindowDraft(task.id), "Separate prompt")
    XCTAssertEqual(store.draft, "Main draft")
    XCTAssertEqual(store.library.tasks.filter(\.isPopoutDraft).count, 1)
  }

  @MainActor func testPopoutHomeCanChooseAnotherProjectWithoutMovingMainWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let current = root.appendingPathComponent("Current", isDirectory: true)
    let selected = root.appendingPathComponent("Selected", isDirectory: true)
    let primary = root.appendingPathComponent("Primary", isDirectory: true)
    for folder in [current, selected, primary] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.projects = [current.path, selected.path]
    store.library.projectPrimaryFolders[selected.path] = primary.path
    store.project = current
    store.draft = "Keep main draft"
    store.popoutHomeDraft = "Popout prompt"

    XCTAssertNil(store.preparePopoutTask(prompt: store.popoutHomeDraft,
      project: root.appendingPathComponent("Removed").path))
    XCTAssertEqual(store.popoutHomeDraft, "Popout prompt")
    XCTAssertEqual(store.library.tasks.count, 0)
    XCTAssertEqual(store.generalSettingsError, "所选项目已不可用，请重新选择项目。")

    store.library.projectPrimaryFolders[selected.path] = root.appendingPathComponent("Missing").path
    XCTAssertNil(store.preparePopoutTask(prompt: store.popoutHomeDraft, project: selected.path))
    XCTAssertEqual(store.popoutHomeDraft, "Popout prompt")
    XCTAssertEqual(store.library.tasks.count, 0)
    XCTAssertNotNil(store.generalSettingsError)
    store.library.projectPrimaryFolders[selected.path] = primary.path
    let task = try XCTUnwrap(store.preparePopoutTask(prompt: store.popoutHomeDraft,
      project: selected.path))
    XCTAssertEqual(task.project, primary.path)
    XCTAssertEqual(store.currentProjectKey, current.path)
    XCTAssertEqual(store.draft, "Keep main draft")
    XCTAssertEqual(store.taskWindowDraft(task.id), "Popout prompt")
    XCTAssertEqual(store.popoutHomeDraft, "")
    XCTAssertNil(store.generalSettingsError)
  }

  @MainActor func testPopoutHomeTransfersAttachmentsAndKeepsOtherDraftsSeparate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.draft = "Main window draft"
    store.popoutHomeDraft = "Popout prompt"
    let unsent = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(unsent.drafts[WorkspaceStore.popoutHomeDraftKey], "Popout prompt")
    let image = ImageAttachment(id: UUID(), name: "screen.png", mimeType: "image/png",
      byteCount: 4, sha256: "image")
    let file = FileAttachment(id: UUID(), name: "notes.txt", byteCount: 5,
      sha256: "file", isPDF: false)
    store.library.draftImages[WorkspaceStore.popoutHomeDraftKey] = [image]
    store.library.draftFiles[WorkspaceStore.popoutHomeDraftKey] = [file]

    let task = try XCTUnwrap(store.preparePopoutTask(prompt: store.popoutHomeDraft,
      projectless: true))
    XCTAssertEqual(store.taskWindowDraft(task.id), "Popout prompt")
    XCTAssertEqual(store.taskWindowImages(task.id).map(\.id), [image.id])
    XCTAssertEqual(store.taskWindowFiles(task.id).map(\.id), [file.id])
    XCTAssertEqual(store.popoutHomeDraft, "")
    XCTAssertTrue(store.popoutHomeImages.isEmpty)
    XCTAssertTrue(store.popoutHomeFiles.isEmpty)
    XCTAssertEqual(store.draft, "Main window draft")

    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.drafts[task.id], "Popout prompt")
    XCTAssertEqual(restored.draftImages[task.id]?.map(\.id), [image.id])
    XCTAssertEqual(restored.draftFiles[task.id]?.map(\.id), [file.id])
    XCTAssertNil(restored.draftImages[WorkspaceStore.popoutHomeDraftKey])
  }

  @MainActor func testPopoutHomeAllowsAttachmentOnlyFirstMessage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    XCTAssertNil(store.preparePopoutTask(prompt: "  ", projectless: true))
    let file = FileAttachment(id: UUID(), name: "notes.txt", byteCount: 5,
      sha256: "file", isPDF: false)
    store.library.draftFiles[WorkspaceStore.popoutHomeDraftKey] = [file]
    let task = try XCTUnwrap(store.preparePopoutTask(prompt: "", projectless: true))
    XCTAssertEqual(store.taskWindowDraft(task.id), "")
    XCTAssertEqual(store.taskWindowFiles(task.id).map(\.id), [file.id])
    XCTAssertTrue(store.popoutHomeFiles.isEmpty)
  }

  @MainActor func testPopoutPermissionsAreCapturedPerTaskAndRemovedWithDiscardedDraft() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let selected = AgentRuntimePreferences(approvalPolicy: .never,
      sandboxMode: .readOnly, networkAccess: false)
    XCTAssertTrue(store.savePopoutHomeRuntimePreferences(selected))
    store.popoutHomeDraft = "Inspect without editing"
    let task = try XCTUnwrap(store.preparePopoutTask(prompt: store.popoutHomeDraft,
      projectless: true))
    XCTAssertEqual(store.runtimePermissions(for: task.id), selected)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .taskRuntimePreferences[task.id], selected)

    XCTAssertTrue(store.saveShowFullAccessInComposer(true))
    XCTAssertTrue(store.saveAgentRuntimePreferences(AgentRuntimePreferences(
      approvalPolicy: .onRequest, sandboxMode: .fullAccess, networkAccess: false)))
    XCTAssertEqual(store.runtimePermissions(for: task.id), selected)
    XCTAssertTrue(store.savePopoutHomeRuntimePreferences(nil))
    store.popoutHomeDraft = "Use the new global permissions"
    let following = try XCTUnwrap(store.preparePopoutTask(prompt: store.popoutHomeDraft,
      projectless: true))
    XCTAssertEqual(store.runtimePermissions(for: following.id).sandboxMode, .fullAccess)
    store.discardPopoutTaskIfEmpty(task.id)
    XCTAssertNil(store.library.taskRuntimePreferences[task.id])
  }

  @MainActor func testPopoutDraftStaysHiddenPromotesOnFirstRunAndEmptyDraftCanBeDiscarded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.popoutWindowProjectlessDefault = true
    let draft = try XCTUnwrap(store.createPopoutTask())
    XCTAssertEqual(store.runtimePermissions(for: draft.id), store.library.agentRuntimePreferences)
    XCTAssertNotNil(store.library.taskRuntimePreferences[draft.id])

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
