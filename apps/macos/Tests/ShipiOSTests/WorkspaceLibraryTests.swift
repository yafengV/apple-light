import XCTest

@testable import ShipiOS

final class WorkspaceLibraryTests: XCTestCase {
  func testPermissionPresetsPairApprovalAndSandboxAndNameCustomCombinations() {
    XCTAssertEqual(AgentRuntimePreferences.askForApproval,
      AgentRuntimePreferences(approvalPolicy: .onRequest,
        sandboxMode: .workspaceWrite, networkAccess: false))
    XCTAssertEqual(AgentRuntimePreferences.fullAccess,
      AgentRuntimePreferences(approvalPolicy: .never,
        sandboxMode: .fullAccess, networkAccess: false))
    XCTAssertEqual(AgentRuntimePreferences.approveForMe,
      AgentRuntimePreferences(approvalPolicy: .onRequest,
        approvalReviewer: .autoReview, sandboxMode: .workspaceWrite,
        networkAccess: false))
    XCTAssertEqual(AgentRuntimePreferences.askForApproval.menuTitle, "按需请求批准")
    XCTAssertEqual(AgentRuntimePreferences.approveForMe.menuTitle, "自动审查批准")
    XCTAssertEqual(AgentRuntimePreferences.fullAccess.menuTitle, "完全访问")
    XCTAssertEqual(AgentRuntimePreferences(approvalPolicy: .onRequest,
      sandboxMode: .fullAccess).menuTitle, "自定义权限")
    XCTAssertEqual(AgentRuntimePreferences(approvalPolicy: .never,
      sandboxMode: .workspaceWrite).menuTitle, "自定义权限")
    XCTAssertEqual(AgentRuntimePreferences(approvalPolicy: .onRequest,
      sandboxMode: .workspaceWrite, networkAccess: true).menuTitle, "自定义权限")
  }

  func testLegacyPermissionsWithoutReviewerDecodeAsUserAndNewSelectionPersists() throws {
    let legacy = Data(#"{"approvalPolicy":"on-request","sandboxMode":"workspace-write","networkAccess":false}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(AgentRuntimePreferences.self, from: legacy),
      .askForApproval)
    let encoded = try JSONEncoder().encode(AgentRuntimePreferences.approveForMe)
    XCTAssertEqual(try JSONDecoder().decode(AgentRuntimePreferences.self, from: encoded),
      .approveForMe)
  }

  @MainActor func testAgentRuntimePermissionsPersistAndRollBackOnSaveFailure() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertEqual(legacy.agentRuntimePreferences, AgentRuntimePreferences())
    XCTAssertFalse(legacy.showAutoReviewInComposer)
    XCTAssertFalse(legacy.showFullAccessInComposer)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-permissions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let selected = AgentRuntimePreferences(approvalPolicy: .never,
      sandboxMode: .fullAccess, networkAccess: true)
    XCTAssertFalse(store.saveAgentRuntimePreferences(selected))
    XCTAssertTrue(store.saveShowFullAccessInComposer(true))
    XCTAssertEqual(store.library.agentRuntimePreferences, AgentRuntimePreferences())
    XCTAssertTrue(store.saveAgentRuntimePreferences(selected))
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .agentRuntimePreferences, selected)

    let blockedRoot = root.appendingPathComponent("blocked")
    let blocked = WorkspaceStore(dataRoot: blockedRoot)
    blocked.libraryLoaded = true
    try FileManager.default.createDirectory(at: blockedRoot.appendingPathComponent("workspace.json"),
      withIntermediateDirectories: true)
    XCTAssertFalse(blocked.saveShowFullAccessInComposer(true))
    XCTAssertFalse(blocked.library.showFullAccessInComposer)
    XCTAssertFalse(blocked.saveAgentRuntimePreferences(AgentRuntimePreferences(
      sandboxMode: .readOnly)))
    XCTAssertEqual(blocked.library.agentRuntimePreferences, AgentRuntimePreferences())
  }

  @MainActor func testFullAccessAvailabilityGatesMenusAndKeepsExistingTaskSnapshots() throws {
    XCTAssertEqual(AgentSandboxMode.visibleOptions(showFullAccess: false),
      [.readOnly, .workspaceWrite])
    XCTAssertEqual(AgentSandboxMode.visibleOptions(showFullAccess: true),
      AgentSandboxMode.allCases)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("full-access-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let full = AgentRuntimePreferences(approvalPolicy: .never,
      sandboxMode: .fullAccess, networkAccess: false)
    XCTAssertFalse(store.savePopoutHomeRuntimePreferences(full))
    XCTAssertTrue(store.saveShowFullAccessInComposer(true))
    XCTAssertTrue(store.saveAgentRuntimePreferences(full))
    XCTAssertTrue(store.savePopoutHomeRuntimePreferences(full))
    store.popoutHomeDraft = "Use current permissions"
    let task = try XCTUnwrap(store.preparePopoutTask(prompt: store.popoutHomeDraft,
      projectless: true))
    XCTAssertEqual(store.runtimePermissions(for: task.id), full)
    XCTAssertTrue(store.saveShowFullAccessInComposer(false))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertFalse(restored.showFullAccessInComposer)
    XCTAssertEqual(restored.agentRuntimePreferences, .askForApproval)
    XCTAssertEqual(restored.popoutHomeRuntimePreferences, .askForApproval)
    XCTAssertEqual(restored.taskRuntimePreferences[task.id], full)
    XCTAssertFalse(store.saveAgentRuntimePreferences(full))
  }

  @MainActor func testComposerPermissionsBelongToDraftOrTaskAndSurviveRestoration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-permissions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let firstDraft = "new:first"
    let secondDraft = "new:second"
    let reviewDraft = "new:review"
    let readOnly = AgentRuntimePreferences(sandboxMode: .readOnly)
    XCTAssertFalse(store.saveComposerRuntimePreferences(.approveForMe,
      taskID: nil, draftKey: reviewDraft))
    XCTAssertTrue(store.saveShowAutoReviewInComposer(true))
    XCTAssertTrue(store.saveComposerRuntimePreferences(readOnly,
      taskID: nil, draftKey: firstDraft))
    XCTAssertEqual(store.composerRuntimePreferences(taskID: nil, draftKey: firstDraft), readOnly)
    XCTAssertEqual(store.composerRuntimePreferences(taskID: nil, draftKey: secondDraft),
      AgentRuntimePreferences())
    XCTAssertTrue(store.saveComposerRuntimePreferences(.approveForMe,
      taskID: nil, draftKey: reviewDraft))

    let task = WorkspaceTask(id: UUID().uuidString, project: "", title: "Existing", runIDs: [])
    store.library.tasks = [task]
    XCTAssertTrue(store.saveLibrary())
    XCTAssertTrue(store.saveShowFullAccessInComposer(true))
    let full = AgentRuntimePreferences(approvalPolicy: .never, sandboxMode: .fullAccess)
    XCTAssertTrue(store.saveComposerRuntimePreferences(full,
      taskID: nil, draftKey: secondDraft))
    XCTAssertTrue(store.saveComposerRuntimePreferences(full,
      taskID: task.id, draftKey: firstDraft))
    XCTAssertEqual(store.composerRuntimePreferences(taskID: task.id, draftKey: secondDraft), full)
    XCTAssertTrue(store.saveShowFullAccessInComposer(false))
    XCTAssertEqual(store.composerRuntimePreferences(taskID: task.id, draftKey: firstDraft), full,
      "Existing task permission snapshots remain visible after hiding the option")
    XCTAssertEqual(store.composerRuntimePreferences(taskID: nil, draftKey: secondDraft),
      .askForApproval)
    XCTAssertFalse(store.saveComposerRuntimePreferences(full,
      taskID: nil, draftKey: secondDraft))
    XCTAssertFalse(store.saveComposerRuntimePreferences(readOnly,
      taskID: "missing", draftKey: firstDraft))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.newTaskRuntimePreferences[firstDraft], readOnly)
    XCTAssertEqual(restored.newTaskRuntimePreferences[reviewDraft], .approveForMe)
    XCTAssertEqual(restored.taskRuntimePreferences[task.id], full)
  }

  func testLegacyFullAccessDefaultsRemainVisibleOnMigration() throws {
    var legacy = WorkspaceLibrary()
    legacy.agentRuntimePreferences.sandboxMode = .fullAccess
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
      as? [String: Any])
    object.removeValue(forKey: "showFullAccessInComposer")
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertTrue(restored.showFullAccessInComposer)
    object["showFullAccessInComposer"] = false
    let inconsistent = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertTrue(inconsistent.showFullAccessInComposer)
  }

  @MainActor func testAutoReviewAvailabilityKeepsExistingTasksAndResetsFutureDefaults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-review-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    XCTAssertFalse(store.saveAgentRuntimePreferences(.approveForMe))
    XCTAssertFalse(store.savePopoutHomeRuntimePreferences(.approveForMe))
    XCTAssertTrue(store.saveShowAutoReviewInComposer(true))
    XCTAssertTrue(store.saveAgentRuntimePreferences(.approveForMe))
    XCTAssertTrue(store.savePopoutHomeRuntimePreferences(.approveForMe))
    let draftKey = "new:review"
    XCTAssertTrue(store.saveComposerRuntimePreferences(.approveForMe,
      taskID: nil, draftKey: draftKey))
    let task = WorkspaceTask(id: UUID().uuidString, project: "", title: "Existing", runIDs: [])
    let inherited = WorkspaceTask(id: UUID().uuidString, project: "", title: "Inherited", runIDs: [])
    store.library.tasks = [task, inherited]
    XCTAssertTrue(store.saveLibrary())
    XCTAssertTrue(store.saveComposerRuntimePreferences(.approveForMe,
      taskID: task.id, draftKey: draftKey))
    XCTAssertTrue(store.saveShowAutoReviewInComposer(false))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertFalse(restored.showAutoReviewInComposer)
    XCTAssertEqual(restored.agentRuntimePreferences, .askForApproval)
    XCTAssertEqual(restored.popoutHomeRuntimePreferences, .askForApproval)
    XCTAssertEqual(restored.newTaskRuntimePreferences[draftKey], .askForApproval)
    XCTAssertEqual(restored.taskRuntimePreferences[task.id], .approveForMe)
    XCTAssertEqual(restored.taskRuntimePreferences[inherited.id], .approveForMe)
    XCTAssertFalse(store.saveComposerRuntimePreferences(.approveForMe,
      taskID: nil, draftKey: "new:next"))
  }

  @MainActor func testChangingDefaultPermissionsPinsLegacyTasksBeforeSwitch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-permissions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let task = WorkspaceTask(id: UUID().uuidString, project: "", title: "Legacy", runIDs: [])
    store.library.tasks = [task]
    XCTAssertTrue(store.saveLibrary())
    XCTAssertNil(store.library.taskRuntimePreferences[task.id])
    XCTAssertTrue(store.saveShowAutoReviewInComposer(true))
    XCTAssertTrue(store.saveAgentRuntimePreferences(.approveForMe))
    XCTAssertEqual(store.runtimePermissions(for: task.id), .askForApproval)
    XCTAssertEqual(store.library.agentRuntimePreferences, .approveForMe)
    XCTAssertTrue(store.saveShowAutoReviewInComposer(false))
    XCTAssertEqual(store.runtimePermissions(for: task.id), .askForApproval)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.taskRuntimePreferences[task.id], .askForApproval)
    XCTAssertEqual(restored.agentRuntimePreferences, .askForApproval)
  }

  func testLegacyAutoReviewDefaultsRemainAvailableOnMigration() throws {
    var legacy = WorkspaceLibrary()
    legacy.agentRuntimePreferences = .approveForMe
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
      as? [String: Any])
    object.removeValue(forKey: "showAutoReviewInComposer")
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertTrue(restored.showAutoReviewInComposer)
  }

  @MainActor func testAgentResponsePreferencesPersistAndMigrate() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertEqual(legacy.agentResponsePreferences, AgentResponsePreferences())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-responses-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let selected = AgentResponsePreferences(verbosity: .high, reasoningSummary: .concise)
    XCTAssertTrue(store.saveAgentResponsePreferences(selected))
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .agentResponsePreferences, selected)
  }

  @MainActor func testAgentWebSearchModeDefaultsOffAndPersists() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertEqual(legacy.agentWebSearchMode, .disabled)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-search-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    XCTAssertTrue(store.saveAgentWebSearchMode(.indexed))
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .agentWebSearchMode, .indexed)
  }

  @MainActor func testAdvancedReasoningEffortsPersistAndKeepStableOrder() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(legacy.enabledAdvancedReasoningEfforts.isEmpty)
    XCTAssertEqual(AgentReasoningEfforts.available(advanced: []),
      ["", "none", "minimal", "low", "medium", "high", "xhigh"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-efforts-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    XCTAssertTrue(store.saveAdvancedReasoningEfforts([.ultra, .max]))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.enabledAdvancedReasoningEfforts, [.max, .ultra])
    XCTAssertEqual(Array(AgentReasoningEfforts.available(advanced: restored.enabledAdvancedReasoningEfforts).suffix(2)),
      ["max", "ultra"])
  }

  @MainActor func testArchiveTimestampMigrationAndRestoreKeepsSettingsOpen() throws {
    let legacy = Data(
      #"{"id":"old","project":"/project","title":"Old","runIDs":["old"],"pinned":false,"archived":true}"#
        .utf8)
    let migrated = try JSONDecoder().decode(WorkspaceTask.self, from: legacy)
    XCTAssertNil(migrated.archivedAt)
    let store = WorkspaceStore()
    store.library.tasks = [migrated]
    store.selection = "old"
    store.openSettings(.archived)
    store.updateTask("old", archive: false)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertNil(store.library.tasks[0].archivedAt)
    store.selection = nil
    store.updateTask("old", archive: true)
    let date = try XCTUnwrap(store.library.tasks[0].archivedAt)
    store.updateTask("old", archive: true)
    XCTAssertEqual(store.library.tasks[0].archivedAt, date)
    let decoded = try JSONDecoder().decode(
      WorkspaceTask.self,
      from: JSONEncoder().encode(store.library.tasks[0]))
    XCTAssertEqual(decoded.archivedAt, date)
  }

  private func run(_ id: String, project: String = "/project") -> AgentRun {
    AgentRun(
      id: id, kind: "doctor", project: project, status: "succeeded", createdAt: 1000,
      updatedAt: 2000,
      request: .object(["kind": .string("doctor")]), result: nil)
  }

  func testLegacyHistoryMigratesOnceAndFollowupsStayInOneTask() {
    var library = WorkspaceLibrary()
    let first = run("first")
    let second = run("second")
    library.reconcile([first], project: "/project")
    library.reconcile([first], project: "/project")
    XCTAssertEqual(library.tasks.count, 1)
    // Cover the event/reply race: the new execution may already exist as a standalone task.
    library.reconcile([second, first], project: "/project")
    library.attach(second, to: "first", note: "再检查一次")
    XCTAssertEqual(library.tasks.count, 1)
    XCTAssertEqual(library.tasks[0].runIDs, ["first", "second"])
    XCTAssertEqual(library.task(containing: "second")?.id, "first")
    XCTAssertEqual(library.notes["second"], "再检查一次")
  }

  @MainActor func testDeletingArchivedTaskCleansPrivateStatePersistsAndDoesNotReconcile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("private context".utf8).write(to: source)
    let file = try FileAttachmentStorage.importFile(source, root: root)
    let image = try ImageAttachmentStorage.importData(
      try AttachmentFixture.png(), name: "private.png", root: root)
    let fileURL = FileAttachmentStorage.url(file, root: root)
    let imageURL = ImageAttachmentStorage.url(image, root: root)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.tasks = [
      .init(id: "archived", project: "/project", title: "Archived", runIDs: ["old"], archived: true),
      .init(id: "active", project: "/project", title: "Active", runIDs: ["keep"]),
    ]
    store.library.chatRuns = [run("old"), run("keep")]
    store.library.notes = ["old": "secret", "keep": "retained"]
    store.library.runFiles["old"] = [file]
    store.library.runImages["old"] = [image]
    store.library.drafts["archived"] = "draft"
    store.library.queuedMessages = [.init(taskID: "archived", text: "later", files: [file])]
    try store.library.save(to: root.appendingPathComponent("workspace.json"))

    store.deleteArchivedTask("archived")

    XCTAssertEqual(store.library.tasks.map(\.id), ["active"])
    XCTAssertEqual(store.library.chatRuns.map(\.id), ["keep"])
    XCTAssertNil(store.library.notes["old"])
    XCTAssertTrue(store.library.deletedRunIDs.contains("old"))
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    var restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    restored.reconcile([run("old"), run("keep")], project: "/project")
    XCTAssertNil(restored.task(containing: "old"))
    XCTAssertNotNil(restored.task(containing: "keep"))
  }

  @MainActor func testDeletingArchivedTasksRollsBackWhenWorkspaceCannotSave() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace.json")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.tasks = [
      .init(id: "archived", project: "/project", title: "Archived", runIDs: ["old"], archived: true)
    ]

    store.deleteAllArchivedTasks()

    XCTAssertEqual(store.library.tasks.map(\.id), ["archived"])
    XCTAssertFalse(store.library.deletedRunIDs.contains("old"))
    XCTAssertNotNil(store.archivedTaskDeletionError)
  }

  @MainActor func testDeleteAllAlsoRemovesLegacyArchivedTaskWithoutRuns() {
    let store = WorkspaceStore()
    store.library.tasks = [
      .init(id: "empty", project: "/project", title: "Legacy empty", runIDs: [], archived: true),
      .init(id: "active", project: "/project", title: "Active", runIDs: ["keep"]),
    ]

    store.deleteAllArchivedTasks()

    XCTAssertEqual(store.library.tasks.map(\.id), ["active"])
    XCTAssertNil(store.archivedTaskDeletionError)
  }

  func testPersistenceSearchArchiveAndProjectIsolation() throws {
    var library = WorkspaceLibrary()
    library.visit("/project")
    library.visit("/another")
    library.visit("/project")
    XCTAssertEqual(library.projects, ["/project", "/another"])
    library.attach(run("one"), to: nil, note: "检查发布前环境")
    library.tasks[0].title = "发布准备"
    library.tasks[0].pinned = true
    library.tasks[0].archived = true
    library.drafts["one"] = "尚未发送的说明"
    var scripts = EnvironmentPlatformScripts()
    scripts.darwin = "swift package resolve"
    library.profiles["/project"] = BuildProfile(
      container: "Demo.xcodeproj", scheme: "Demo", configuration: "Release",
      worktreeSetupScript: "echo default", setupPlatformScripts: scripts,
      worktreeCleanupScript: "echo cleanup", cleanupPlatformScripts: scripts,
      actions: [EnvironmentAction(title: "Build", symbol: "tool", script: "swift build",
        platform: .darwin)])
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let file = temp.appendingPathComponent("workspace.json")
    try library.save(to: file)
    let restored = try WorkspaceLibrary.load(from: file)
    XCTAssertTrue(restored.visible(project: "/project", query: "", archived: false).isEmpty)
    XCTAssertEqual(restored.visible(project: "/project", query: "发布前", archived: true).count, 1)
    XCTAssertTrue(restored.visible(project: "/another", query: "发布", archived: true).isEmpty)
    XCTAssertEqual(restored.drafts["one"], "尚未发送的说明")
    XCTAssertEqual(restored.profiles["/project"]?.configuration, "Release")
    XCTAssertEqual(restored.profiles["/project"]?.worktreeSetupScript, "echo default")
    XCTAssertEqual(restored.profiles["/project"]?.setupPlatformScripts, scripts)
    XCTAssertEqual(restored.profiles["/project"]?.macOSSetupScript, "swift package resolve")
    XCTAssertEqual(restored.profiles["/project"]?.worktreeCleanupScript, "echo cleanup")
    XCTAssertEqual(restored.profiles["/project"]?.macOSCleanupScript, "swift package resolve")
    XCTAssertEqual(restored.profiles["/project"]?.actions.first?.title, "Build")
    XCTAssertEqual(restored.profiles["/project"]?.actions.first?.platform, .darwin)
    XCTAssertTrue(restored.tasks[0].pinned)
  }

  func testLegacyBuildProfileWithoutSetupScriptLoads() throws {
    let profile = try JSONDecoder().decode(BuildProfile.self,
      from: Data(#"{"container":"Demo.xcodeproj","scheme":"Demo","configuration":"Debug"}"#.utf8))
    XCTAssertEqual(profile.worktreeSetupScript, "")
    XCTAssertEqual(profile.setupPlatformScripts, .init())
    XCTAssertEqual(profile.worktreeCleanupScript, "")
    XCTAssertEqual(profile.cleanupPlatformScripts, .init())
    XCTAssertEqual(profile.actions, [])
  }

  func testLegacyActionIconAndMissingPlatformMigrate() throws {
    var action = try JSONDecoder().decode(EnvironmentAction.self,
      from: Data(#"{"title":"Build","symbol":"hammer","script":"swift build"}"#.utf8))
    XCTAssertEqual(action.symbol, "tool")
    XCTAssertEqual(action.platform, .all)
    XCTAssertTrue(action.isRunnableOnMac)
    action.platform = .linux
    XCTAssertFalse(action.isRunnableOnMac)
  }

  func testSlashActionsAreExplicitAndNeverTreatNotesAsModelPrompts() throws {
    let (doctor, note) = try LocalAction.parse(" /doctor 检查环境 ", fallback: .build)
    XCTAssertEqual(doctor, .doctor)
    XCTAssertEqual(note, "检查环境")
    let (build, description) = try LocalAction.parse("修复我的项目", fallback: .build)
    XCTAssertEqual(build, .build)
    XCTAssertEqual(description, "修复我的项目")
    XCTAssertThrowsError(try LocalAction.parse("/deploy", fallback: .doctor))
    XCTAssertEqual(try LocalAction.parse("/build", fallback: .doctor).0, .build)
  }

  func testCorruptWorkspaceIsNotSilentlyReplaced() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("broken".utf8).write(to: temp)
    defer { try? FileManager.default.removeItem(at: temp) }
    XCTAssertThrowsError(try WorkspaceLibrary.load(from: temp))
    XCTAssertEqual(try String(contentsOf: temp, encoding: .utf8), "broken")
  }
}
